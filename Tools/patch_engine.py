import lzma
import struct
import sys
import zlib

NEED_ACTIVATION = 0x02

OPERANDS = {
    0x04: "u", 0x05: "u", 0x06: "u", 0x08: "u", 0x24: "b", 0x25: "u", 0x2C: "u", 0x2D: "u", 0x2E: "u", 0x2F: "u",
    0x31: "u", 0x32: "uu", 0x40: "u", 0x41: "u", 0x42: "u", 0x43: "uu", 0x44: "uu", 0x45: "uu", 0x46: "uu",
    0x49: "u", 0x4A: "uu", 0x4C: "uu", 0x4E: "uu", 0x4F: "uu", 0x53: "u", 0x55: "u", 0x56: "u", 0x58: "u",
    0x59: "u", 0x5A: "u", 0x5D: "u", 0x5E: "u", 0x60: "u", 0x61: "u", 0x62: "u", 0x63: "u", 0x65: "u", 0x66: "u",
    0x68: "u", 0x6A: "u", 0x6C: "u", 0x6D: "u", 0x6E: "u", 0x6F: "u", 0x80: "u", 0x86: "u", 0x92: "u", 0x94: "u",
    0xB2: "u", 0xC2: "u", 0xC3: "u", 0xEF: "bubu", 0xF0: "u", 0xF1: "u",
}
OPERANDS.update({op: "j" for op in range(0x0C, 0x1B)})


class Reader:
    def __init__(self, data, pos=0):
        self.data = data
        self.pos = pos

    def u8(self):
        value = self.data[self.pos]
        self.pos += 1
        return value

    def u30(self):
        result = shift = 0
        while True:
            byte = self.u8()
            result |= (byte & 0x7F) << shift
            shift += 7
            if not byte & 0x80 or shift >= 35:
                return result

    def skip(self, count):
        self.pos += count


def u30(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def load_swf(path):
    data = open(path, "rb").read()
    signature, version = data[:3], data[3]
    if signature == b"FWS":
        body = data[8:]
    elif signature == b"CWS":
        body = zlib.decompress(data[8:])
    elif signature == b"ZWS":
        props = data[12:17]
        filters = [lzma._decode_filter_properties(lzma.FILTER_LZMA1, props)]
        body = lzma.LZMADecompressor(format=lzma.FORMAT_RAW, filters=filters).decompress(data[17:])
    else:
        sys.exit(f"{path}: não é um SWF")
    return version, bytearray(body)


def find_abc(body):
    bits = body[0] >> 3
    pos = (5 + 4 * bits + 7) // 8 + 4
    while pos < len(body):
        header = struct.unpack_from("<H", body, pos)[0]
        code, length, start = header >> 6, header & 0x3F, pos + 2
        if length == 0x3F:
            length = struct.unpack_from("<I", body, start)[0]
            start += 4
        if code == 82:
            name_end = body.index(0, start + 4)
            return pos, start, length, name_end + 1
        pos = start + length
    sys.exit("DoABC não encontrado")


def parse(abc):
    r = Reader(abc, 4)
    for _ in range(max(0, r.u30() - 1)):
        r.u30()
    for _ in range(max(0, r.u30() - 1)):
        r.u30()
    r.skip(8 * max(0, r.u30() - 1))
    r.skip(4 * max(0, r.u30() - 1))
    strings_start = r.pos
    strings = [""]
    for _ in range(max(0, r.u30() - 1)):
        length = r.u30()
        strings.append(abc[r.pos:r.pos + length].decode("utf-8"))
        r.skip(length)
    strings_end = r.pos
    for _ in range(max(0, r.u30() - 1)):
        r.u8()
        r.u30()
    for _ in range(max(0, r.u30() - 1)):
        for _ in range(r.u30()):
            r.u30()
    names = ["*"]
    for _ in range(max(0, r.u30() - 1)):
        kind = r.u8()
        if kind in (0x07, 0x0D):
            r.u30()
            names.append(strings[r.u30()])
        elif kind in (0x0F, 0x10):
            names.append(strings[r.u30()])
        elif kind in (0x11, 0x12):
            names.append(None)
        elif kind in (0x09, 0x0E):
            names.append(strings[r.u30()])
            r.u30()
        elif kind in (0x1B, 0x1C):
            r.u30()
            names.append(None)
        elif kind == 0x1D:
            base = r.u30()
            for _ in range(r.u30()):
                r.u30()
            names.append(names[base])
        else:
            sys.exit(f"multiname desconhecido {kind:#x}")
    method_flags = []
    for _ in range(r.u30()):
        params = r.u30()
        r.u30()
        for _ in range(params):
            r.u30()
        r.u30()
        method_flags.append(r.pos)
        flags = r.u8()
        if flags & 0x08:
            for _ in range(r.u30()):
                r.u30()
                r.u8()
        if flags & 0x80:
            for _ in range(params):
                r.u30()
    for _ in range(r.u30()):
        r.u30()
        for _ in range(r.u30()):
            r.u30()
            r.u30()
    method_names = {}

    def traits(owner):
        for _ in range(r.u30()):
            name = names[r.u30()]
            tag = r.u8()
            kind = tag & 0x0F
            if kind in (0, 6):
                r.u30()
                r.u30()
                if r.u30():
                    r.u8()
            elif kind in (1, 2, 3, 5):
                r.u30()
                method_names[r.u30()] = f"{owner}.{name}"
            elif kind == 4:
                r.u30()
                r.u30()
            if tag & 0x40:
                for _ in range(r.u30()):
                    r.u30()

    classes = []
    for _ in range(r.u30()):
        name = names[r.u30()]
        r.u30()
        if r.u8() & 0x08:
            r.u30()
        for _ in range(r.u30()):
            r.u30()
        r.u30()
        traits(name)
        classes.append(name)
    for name in classes:
        r.u30()
        traits(name)
    for _ in range(r.u30()):
        r.u30()
        traits("script")
    bodies = {}
    for _ in range(r.u30()):
        start = r.pos
        method = r.u30()
        r.u30()
        r.u30()
        r.u30()
        r.u30()
        length = r.u30()
        code = (r.pos, r.pos + length)
        r.skip(length)
        for _ in range(r.u30()):
            for _ in range(5):
                r.u30()
        traits("body")
        bodies[method_names.get(method, f"#{method}")] = (start, r.pos, method, code)
    return strings, (strings_start, strings_end), names, method_flags, bodies


def instructions(abc, span):
    r = Reader(abc, span[0])
    while r.pos < span[1]:
        op = r.u8()
        args = []
        if op == 0x1B:
            r.skip(3)
            r.skip(3 * (r.u30() + 1))
        for kind in OPERANDS.get(op, ""):
            if kind == "u":
                args.append(r.u30())
            elif kind == "b":
                args.append(r.u8())
            elif kind == "j":
                r.skip(3)
        yield op, args


def patch(source, target):
    version, body = load_swf(source)
    tag_pos, tag_start, tag_length, abc_start = find_abc(body)
    abc = bytes(body[abc_start:tag_start + tag_length])
    strings, pool, names, method_flags, bodies = parse(abc)

    if "Engine.shot" not in bodies:
        sys.exit("Engine.swf já está adaptado ou é de outra versão")

    stage = native_window = title = None
    for op, args in instructions(abc, bodies["Engine.onInvoke"][3]):
        if op == 0x60 and names[args[0]] == "stage":
            stage = args[0]
        elif op == 0x66 and names[args[0]] == "nativeWindow":
            native_window = args[0]
        elif op == 0x61 and names[args[0]] == "title":
            title = args[0]
    if None in (stage, native_window, title):
        sys.exit("não achei stage.nativeWindow.title no motor")

    start, end, method, _ = bodies["Engine.shot"]
    r = Reader(abc, start)
    r.u30()
    r.u30()
    r.u30()
    init_scope = r.u30()
    code = (
        b"\xd0\x30"
        + b"\x60" + u30(stage)
        + b"\x66" + u30(native_window)
        + b"\xd1"
        + b"\x61" + u30(title)
        + b"\x47"
    )
    new_body = u30(method) + u30(2) + u30(2) + u30(init_scope) + u30(init_scope + 1) + u30(len(code)) + code + u30(0) + u30(0)

    shot = strings.index("shot")
    new_pool = bytearray(u30(len(strings)))
    for index in range(1, len(strings)):
        value = ("title" if index == shot else strings[index]).encode("utf-8")
        new_pool += u30(len(value)) + value

    patched = bytearray(abc)
    patched[method_flags[method]] &= ~NEED_ACTIVATION & 0xFF
    patched[start:end] = new_body
    patched[pool[0]:pool[1]] = new_pool

    new_tag_length = abc_start - tag_start + len(patched)
    tag = struct.pack("<HI", (82 << 6) | 0x3F, new_tag_length) + body[tag_start:abc_start] + patched
    new_body_swf = body[:tag_pos] + tag + body[tag_start + tag_length:]
    compressed = zlib.compress(bytes(new_body_swf), 9)
    with open(target, "wb") as out:
        out.write(b"CWS" + bytes([version]) + struct.pack("<I", len(new_body_swf) + 8) + compressed)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("uso: patch_engine.py <Engine.swf original> <saída>")
    patch(sys.argv[1], sys.argv[2])
