"""GeoFinder – serwer koordynujący przeszukiwanie terenu.

Uruchomienie:  uvicorn app:app --host 0.0.0.0 --port 8000
"""
import json
import os
import secrets
import sqlite3
import time
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, Header, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

BASE = Path(__file__).parent
DB_PATH = os.environ.get("GEOFINDER_DB", str(BASE / "geofinder.db"))
WEB_DIR = Path(os.environ.get("GEOFINDER_WEB", BASE / "web"))   # wynik `flutter build web`

COLORS = ["#e6194b", "#3cb44b", "#4363d8", "#f58231", "#911eb4", "#42d4f4", "#f032e6",
          "#9a6324", "#800000", "#808000", "#000075", "#469990", "#bfef45", "#dcbeff"]

CATEGORIES = {
    "trace": ("Ślad", "znaleziono ślad"),
    "item": ("Przedmiot", "znaleziono przedmiot"),
    "person": ("Osoba", "odnaleziono osobę"),
    "danger": ("Zagrożenie", "zgłoszono zagrożenie"),
    "other": ("Inne", "nowe zgłoszenie"),
}

DEFAULT_SETTINGS = {
    "name": "Akcja poszukiwawcza",
    "area": None,          # {"north", "south", "east", "west"}
    "rows": 10,
    "cols": 10,
    "calib": None,         # {"lat", "lon"} – punkt kalibracyjny GPS
    "default_radius": 10.0,
    "max_accuracy": 25.0,  # odrzucamy pozycje z gorszą dokładnością (m)
}

# ---------------------------------------------------------------- baza danych

db = sqlite3.connect(DB_PATH, check_same_thread=False)
db.row_factory = sqlite3.Row
db.executescript("""
CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    token TEXT NOT NULL UNIQUE,
    radius REAL NOT NULL,
    color TEXT NOT NULL,
    calib TEXT,
    lat REAL, lon REAL, acc REAL,
    last_seen REAL
);
CREATE TABLE IF NOT EXISTS points (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    lat REAL NOT NULL, lon REAL NOT NULL,
    r REAL NOT NULL,
    t REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS reports (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    lat REAL NOT NULL, lon REAL NOT NULL,
    cell TEXT,
    category TEXT NOT NULL,
    text TEXT NOT NULL,
    t REAL NOT NULL
);
""")
db.commit()


def kv_get(key, default=None):
    row = db.execute("SELECT v FROM kv WHERE k=?", (key,)).fetchone()
    return json.loads(row["v"]) if row else default


def kv_set(key, value):
    db.execute("INSERT OR REPLACE INTO kv (k, v) VALUES (?, ?)", (key, json.dumps(value)))
    db.commit()


def secret(key, env, factory):
    """Klucz z env, a jeśli go brak – wygenerowany raz i zapamiętany w bazie."""
    if os.environ.get(env):
        return os.environ[env]
    value = kv_get(key)
    if not value:
        value = factory()
        kv_set(key, value)
    return value


ADMIN_KEY = secret("admin_key", "ADMIN_KEY", lambda: secrets.token_urlsafe(9))
JOIN_CODE = secret("join_code", "JOIN_CODE", lambda: f"{secrets.randbelow(10**6):06d}")


def get_settings():
    return {**DEFAULT_SETTINGS, **kv_get("settings", {})}


# ---------------------------------------------------------------- siatka

def col_label(i):
    """0 -> A, 25 -> Z, 26 -> AA"""
    s, n = "", i + 1
    while n:
        n, rem = divmod(n - 1, 26)
        s = chr(65 + rem) + s
    return s


def cell_of(settings, lat, lon):
    a = settings["area"]
    if not a or not (a["south"] <= lat <= a["north"] and a["west"] <= lon <= a["east"]):
        return None
    col = min(int((lon - a["west"]) / (a["east"] - a["west"]) * settings["cols"]), settings["cols"] - 1)
    row = min(int((a["north"] - lat) / (a["north"] - a["south"]) * settings["rows"]), settings["rows"] - 1)
    return f"{col_label(col)}{row + 1}"


# ---------------------------------------------------------------- serializacja

def user_json(row):
    return {
        "id": row["id"], "name": row["name"], "radius": row["radius"], "color": row["color"],
        "calib": json.loads(row["calib"]) if row["calib"] else None,
        "lat": row["lat"], "lon": row["lon"], "acc": row["acc"], "last_seen": row["last_seen"],
    }


def report_json(row):
    label, verb = CATEGORIES.get(row["category"], CATEGORIES["other"])
    where = f"W kwadracie {row['cell']}" if row["cell"] else f"Poza siatką ({row['lat']:.5f}, {row['lon']:.5f})"
    user = db.execute("SELECT name FROM users WHERE id=?", (row["user_id"],)).fetchone()
    return {
        "id": row["id"], "user": row["user_id"], "user_name": user["name"] if user else "?",
        "lat": row["lat"], "lon": row["lon"], "cell": row["cell"],
        "category": row["category"], "category_label": label, "text": row["text"], "t": row["t"],
        "message": f"{where} {verb}",
    }


def point_json(row):
    # zwięzły format: [id, user, lat, lon, radius, t]
    return [row["id"], row["user_id"], row["lat"], row["lon"], row["r"], row["t"]]


# ---------------------------------------------------------------- autoryzacja

def auth(authorization: Optional[str]):
    token = (authorization or "").removeprefix("Bearer ").strip()
    if token and secrets.compare_digest(token, ADMIN_KEY):
        return "admin", None
    if token:
        user = db.execute("SELECT * FROM users WHERE token=?", (token,)).fetchone()
        if user:
            return "user", user
    raise HTTPException(401, "Brak autoryzacji")


def require_admin(authorization):
    role, _ = auth(authorization)
    if role != "admin":
        raise HTTPException(403, "Tylko dla administratora")


def require_user(authorization):
    role, user = auth(authorization)
    if role != "user":
        raise HTTPException(403, "Tylko dla uczestnika")
    return user


# ---------------------------------------------------------------- websocket

clients: set[WebSocket] = set()


async def broadcast(msg):
    data = json.dumps(msg)
    for ws in list(clients):
        try:
            await ws.send_text(data)
        except Exception:
            clients.discard(ws)


# ---------------------------------------------------------------- API

app = FastAPI(title="GeoFinder")
# autoryzacja idzie nagłówkiem Bearer (bez ciasteczek), więc dowolne źródło jest bezpieczne
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])


@app.on_event("startup")
async def startup():
    print("=" * 60)
    print(f"  GeoFinder – aplikacja web:  http://<adres-serwera>:8000/")
    print(f"  Klucz administratora:       {ADMIN_KEY}")
    print(f"  Kod dołączenia uczestników: {JOIN_CODE}")
    if not WEB_DIR.exists():
        print(f"  (brak {WEB_DIR} – zbuduj: flutter build web, patrz README)")
    print("=" * 60, flush=True)


class JoinIn(BaseModel):
    name: str = Field(min_length=1, max_length=40)
    code: str


@app.post("/api/join")
async def join(body: JoinIn):
    if body.code.strip() != JOIN_CODE:
        raise HTTPException(403, "Zły kod dołączenia")
    token = secrets.token_urlsafe(24)
    count = db.execute("SELECT COUNT(*) FROM users").fetchone()[0]
    cur = db.execute("INSERT INTO users (name, token, radius, color) VALUES (?, ?, ?, ?)",
                     (body.name.strip(), token, get_settings()["default_radius"], COLORS[count % len(COLORS)]))
    db.commit()
    user = db.execute("SELECT * FROM users WHERE id=?", (cur.lastrowid,)).fetchone()
    await broadcast({"type": "user", "user": user_json(user)})
    return {"token": token, "user": user_json(user)}


@app.get("/api/state")
async def state(authorization: Optional[str] = Header(None)):
    role, me = auth(authorization)
    out = {
        "role": role,
        "settings": get_settings(),
        "categories": {k: v[0] for k, v in CATEGORIES.items()},
        "users": [user_json(u) for u in db.execute("SELECT * FROM users ORDER BY id")],
        "reports": [report_json(r) for r in db.execute("SELECT * FROM reports ORDER BY id")],
        "me": user_json(me) if me else None,
    }
    if role == "admin":
        out["join_code"] = JOIN_CODE
    return out


@app.get("/api/points")
async def points(since: int = 0, authorization: Optional[str] = Header(None)):
    auth(authorization)
    rows = db.execute("SELECT * FROM points WHERE id>? ORDER BY id", (since,))
    return [point_json(r) for r in rows]


class FixIn(BaseModel):
    lat: float
    lon: float
    acc: float = 0
    t: Optional[float] = None


class PointsIn(BaseModel):
    points: list[FixIn]
    record: bool = True   # False = tylko aktualizacja pozycji, bez malowania pokrycia


@app.post("/api/points")
async def add_points(body: PointsIn, authorization: Optional[str] = Header(None)):
    user = require_user(authorization)
    if not body.points:
        return {"added": 0}
    max_acc = get_settings()["max_accuracy"]
    now = time.time()
    added = []
    if body.record:
        for p in body.points:
            if p.acc > max_acc:
                continue
            cur = db.execute("INSERT INTO points (user_id, lat, lon, r, t) VALUES (?, ?, ?, ?, ?)",
                             (user["id"], p.lat, p.lon, user["radius"], p.t or now))
            added.append([cur.lastrowid, user["id"], p.lat, p.lon, user["radius"], p.t or now])
    last = body.points[-1]
    db.execute("UPDATE users SET lat=?, lon=?, acc=?, last_seen=? WHERE id=?",
               (last.lat, last.lon, last.acc, now, user["id"]))
    db.commit()
    if added:
        await broadcast({"type": "points", "points": added})
    await broadcast({"type": "pos", "id": user["id"], "lat": last.lat, "lon": last.lon,
                     "acc": last.acc, "last_seen": now})
    return {"added": len(added)}


class CalibIn(BaseModel):
    dlat: float
    dlon: float
    acc: float
    spread: float
    samples: int


@app.post("/api/calibration")
async def calibration(body: CalibIn, authorization: Optional[str] = Header(None)):
    user = require_user(authorization)
    calib = {**body.model_dump(), "t": time.time()}
    db.execute("UPDATE users SET calib=? WHERE id=?", (json.dumps(calib), user["id"]))
    db.commit()
    row = db.execute("SELECT * FROM users WHERE id=?", (user["id"],)).fetchone()
    await broadcast({"type": "user", "user": user_json(row)})
    return {"ok": True}


class ReportIn(BaseModel):
    lat: float
    lon: float
    category: str = "other"
    text: str = Field("", max_length=500)


@app.post("/api/reports")
async def add_report(body: ReportIn, authorization: Optional[str] = Header(None)):
    user = require_user(authorization)
    category = body.category if body.category in CATEGORIES else "other"
    cell = cell_of(get_settings(), body.lat, body.lon)
    cur = db.execute("INSERT INTO reports (user_id, lat, lon, cell, category, text, t) VALUES (?, ?, ?, ?, ?, ?, ?)",
                     (user["id"], body.lat, body.lon, cell, category, body.text.strip(), time.time()))
    db.commit()
    report = report_json(db.execute("SELECT * FROM reports WHERE id=?", (cur.lastrowid,)).fetchone())
    await broadcast({"type": "report", "report": report})
    return report


# ---------------------------------------------------------------- API admina

class AreaIn(BaseModel):
    north: float
    south: float
    east: float
    west: float


class CalibPointIn(BaseModel):
    lat: float
    lon: float


class SettingsIn(BaseModel):
    name: Optional[str] = None
    area: Optional[AreaIn] = None
    rows: Optional[int] = Field(None, ge=1, le=200)
    cols: Optional[int] = Field(None, ge=1, le=200)
    calib: Optional[CalibPointIn] = None
    default_radius: Optional[float] = Field(None, gt=0, le=500)
    max_accuracy: Optional[float] = Field(None, gt=0, le=500)


@app.put("/api/settings")
async def put_settings(body: SettingsIn, authorization: Optional[str] = Header(None)):
    require_admin(authorization)
    settings = get_settings()
    patch = body.model_dump(exclude_unset=True)
    if patch.get("area"):
        a = patch["area"]
        if a["north"] <= a["south"] or a["east"] <= a["west"]:
            raise HTTPException(400, "Niepoprawny obszar")
    settings.update(patch)
    kv_set("settings", settings)
    await broadcast({"type": "settings", "settings": settings})
    return settings


class UserPatch(BaseModel):
    name: Optional[str] = Field(None, min_length=1, max_length=40)
    radius: Optional[float] = Field(None, gt=0, le=500)
    color: Optional[str] = Field(None, pattern=r"^#[0-9a-fA-F]{6}$")


@app.put("/api/users/{user_id}")
async def put_user(user_id: int, body: UserPatch, authorization: Optional[str] = Header(None)):
    require_admin(authorization)
    for field, value in body.model_dump(exclude_unset=True).items():
        db.execute(f"UPDATE users SET {field}=? WHERE id=?", (value, user_id))
    db.commit()
    row = db.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
    if not row:
        raise HTTPException(404)
    await broadcast({"type": "user", "user": user_json(row)})
    return user_json(row)


@app.delete("/api/users/{user_id}")
async def delete_user(user_id: int, authorization: Optional[str] = Header(None)):
    require_admin(authorization)
    # punkty zostają – teren przeszukany przez tę osobę nadal jest przeszukany
    db.execute("DELETE FROM users WHERE id=?", (user_id,))
    db.commit()
    await broadcast({"type": "user_deleted", "id": user_id})
    return {"ok": True}


@app.delete("/api/reports/{report_id}")
async def delete_report(report_id: int, authorization: Optional[str] = Header(None)):
    require_admin(authorization)
    db.execute("DELETE FROM reports WHERE id=?", (report_id,))
    db.commit()
    await broadcast({"type": "report_deleted", "id": report_id})
    return {"ok": True}


@app.post("/api/coverage/clear")
async def clear_coverage(authorization: Optional[str] = Header(None)):
    require_admin(authorization)
    db.execute("DELETE FROM points")
    db.commit()
    await broadcast({"type": "reset"})
    return {"ok": True}


@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket, token: str = ""):
    try:
        auth(f"Bearer {token}")
    except HTTPException:
        await ws.close(code=4401)
        return
    await ws.accept()
    clients.add(ws)
    try:
        while True:
            await ws.receive_text()   # klient może wysyłać "ping"; nic więcej nie odbieramy
    except WebSocketDisconnect:
        pass
    finally:
        clients.discard(ws)


# Webowa wersja aplikacji Flutter (montowana na końcu, żeby nie przysłaniała /api i /ws)
if WEB_DIR.exists():
    app.mount("/", StaticFiles(directory=WEB_DIR, html=True), name="web")
