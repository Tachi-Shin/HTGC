"""Utilities shared by the C source generators."""


def c_string(text):
    result = []
    for byte in text.encode("utf-8"):
        if byte in (34, 92):
            result.append("\\" + chr(byte))
        elif 32 <= byte <= 126 and byte != 63:
            result.append(chr(byte))
        else:
            result.append(f"\\{byte:03o}")
    return '"' + "".join(result) + '"'
