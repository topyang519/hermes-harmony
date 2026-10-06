"""Small, self-hostable WebSocket relay. It never connects to Hermes itself."""

from __future__ import annotations

import argparse
import asyncio
import hmac
import hashlib
import ipaddress
import json
import logging
import os
import re
import secrets
from dataclasses import dataclass, field

from aiohttp import WSMsgType, web

from hermes_harmony_bridge.server import RedactingAccessLogger

log = logging.getLogger(__name__)
ROOM = re.compile(r"[a-f0-9]{32}\Z")
CONNECTION_ID = ROOM
MAX_FRAME = 8 * 1024 * 1024
MAX_ROOMS = 512
MAX_ROOMS_PER_IP = 32


@dataclass
class Room:
    host: web.WebSocketResponse
    phone_token: str
    owner_ip: str
    phones: dict[str, web.WebSocketResponse] = field(default_factory=dict)
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    join_lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    async def to_host(self, payload: str | bytes) -> None:
        async with self.lock:
            if isinstance(payload, str):
                await self.host.send_str(payload)
            else:
                await self.host.send_bytes(payload)


def create_relay_app() -> web.Application:
    app = web.Application(client_max_size=MAX_FRAME)
    rooms: dict[str, Room] = {}
    registration_lock = asyncio.Lock()
    app["rooms"] = rooms

    async def health(_request: web.Request) -> web.Response:
        return web.json_response({"ok": True})

    async def host(request: web.Request) -> web.StreamResponse:
        room_id = request.match_info["room"]
        token = request.headers.get("X-Hermes-Host-Token", "")
        phone_token = request.headers.get("X-Hermes-Phone-Token", "")
        expected_room = hashlib.sha256(token.encode()).hexdigest()[:32]
        if not ROOM.fullmatch(room_id) or len(token) < 32 or len(phone_token) < 32 or not hmac.compare_digest(room_id, expected_room):
            raise web.HTTPBadRequest(text="invalid room credentials")
        forwarded = request.headers.get("X-Real-IP", "") if request.remote in ("127.0.0.1", "::1") else ""
        try:
            ip = str(ipaddress.ip_address(forwarded or request.remote or ""))
        except ValueError:
            ip = request.remote or "unknown"
        ws = web.WebSocketResponse(heartbeat=30, max_msg_size=MAX_FRAME)
        async with registration_lock:
            if room_id in rooms:
                raise web.HTTPConflict(text="room already online")
            if len(rooms) >= MAX_ROOMS or sum(room.owner_ip == ip for room in rooms.values()) >= MAX_ROOMS_PER_IP:
                raise web.HTTPServiceUnavailable(text="relay capacity reached")
            await ws.prepare(request)
            current = Room(ws, phone_token, ip)
            rooms[room_id] = current
        log.info("host online room=%s", room_id[:8])
        try:
            async for message in ws:
                if message.type == WSMsgType.TEXT:
                    try:
                        data = json.loads(message.data)
                        cid = data["id"]
                        op = data["op"]
                    except (ValueError, KeyError, TypeError):
                        continue
                    if not isinstance(cid, str) or not CONNECTION_ID.fullmatch(cid):
                        continue
                    phone = current.phones.get(cid)
                    if phone is None:
                        continue
                    if op == "data" and isinstance(data.get("text"), str):
                        await phone.send_str(data["text"])
                    elif op == "close":
                        await phone.close()
                elif message.type == WSMsgType.BINARY and len(message.data) >= 16:
                    cid = message.data[:16].hex()
                    phone = current.phones.get(cid)
                    if phone is not None:
                        await phone.send_bytes(message.data[16:])
        finally:
            if rooms.get(room_id) is current:
                rooms.pop(room_id, None)
            await asyncio.gather(*(phone.close() for phone in list(current.phones.values())), return_exceptions=True)
            log.info("host offline room=%s", room_id[:8])
        return ws

    async def phone(request: web.Request) -> web.StreamResponse:
        room_id = request.match_info["room"]
        current = rooms.get(room_id)
        token = request.query.get("password", "")
        if current is None:
            raise web.HTTPServiceUnavailable(text="computer offline")
        if not token or not hmac.compare_digest(token, current.phone_token):
            raise web.HTTPUnauthorized(text="invalid pairing credential")
        ws = web.WebSocketResponse(heartbeat=30, max_msg_size=MAX_FRAME)
        cid = secrets.token_bytes(16)
        cid_hex = cid.hex()
        async with current.join_lock:
            if len(current.phones) >= 4:
                raise web.HTTPServiceUnavailable(text="too many phones")
            await ws.prepare(request)
            current.phones[cid_hex] = ws
        try:
            await current.to_host(json.dumps({"op": "open", "id": cid_hex}))
            async for message in ws:
                if message.type == WSMsgType.TEXT:
                    await current.to_host(json.dumps({"op": "data", "id": cid_hex, "text": message.data}))
                elif message.type == WSMsgType.BINARY:
                    await current.to_host(cid + message.data)
        finally:
            current.phones.pop(cid_hex, None)
            if not current.host.closed:
                try:
                    await current.to_host(json.dumps({"op": "close", "id": cid_hex}))
                except ConnectionError:
                    pass
        return ws

    async def cleanup(_app: web.Application) -> None:
        await asyncio.gather(*(room.host.close() for room in list(rooms.values())), return_exceptions=True)

    app.router.add_get("/healthz", health)
    app.router.add_get("/relay/host/{room}", host)
    app.router.add_get("/relay/phone/{room}", phone)
    app.on_cleanup.append(cleanup)
    return app


def main() -> None:
    parser = argparse.ArgumentParser(description="Hermes Harmony public relay")
    parser.add_argument("--host", default=os.environ.get("HERMES_RELAY_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("HERMES_RELAY_PORT", "8765")))
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO)
    web.run_app(create_relay_app(), host=args.host, port=args.port, access_log_class=RedactingAccessLogger)


if __name__ == "__main__":
    main()
