import socket, struct, time

SRC = "192.168.1.218"
DST = "224.0.0.1"

def checksum(data):
    if len(data) % 2:
        data += b"\x00"
    s = sum(struct.unpack("!%dH" % (len(data) // 2), data))
    s = (s >> 16) + (s & 0xFFFF)
    s += s >> 16
    return (~s) & 0xFFFF

def build_query():
    igmp = struct.pack("!BBHI", 0x11, 100, 0, 0)
    igmp = struct.pack("!BBHI", 0x11, 100, checksum(igmp), 0)
    opts = b"\x94\x04\x00\x00"
    ihl = 6
    total = ihl * 4 + len(igmp)
    ip = struct.pack("!BBHHHBBH4s4s", (4 << 4) | ihl, 0, total, 0, 0, 1,
                     socket.IPPROTO_IGMP, 0,
                     socket.inet_aton(SRC), socket.inet_aton(DST)) + opts
    ip = ip[:10] + struct.pack("!H", checksum(ip)) + ip[12:]
    return ip + igmp

sock = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_RAW)
sock.setsockopt(socket.IPPROTO_IP, socket.IP_HDRINCL, 1)
print("igmp-querier: sending general queries every 60s", flush=True)
while True:
    sock.sendto(build_query(), (DST, 0))
    time.sleep(60)
