//
//  RoutingTable.swift
//  RoutingDiag / Extension
//
//  Two diagnostics that work in iOS Network Extensions without
//  special entitlements:
//
//  1. `dumpInterfaces()` — `getifaddrs(3)`, the standard way to list
//     interface names / addresses / flags.
//
//  2. `dumpRoutes(family:)` —
//     `sysctl(CTL_NET, PF_ROUTE, 0, AF_INET|AF_INET6, NET_RT_DUMP, 0)`,
//     the same way `netstat -rn` queries the kernel. The rt_msghdr
//     layout and RTAX_* / RTF_* constants live in
//     BridgingHeader.h (iOS SDK omits `<net/route.h>`).
//
//  All `withMemoryRebound` closures keep their rebound pointer
//  strictly local — escaping such a pointer past the closure is
//  undefined behavior, and earlier versions of this file did so.
//

import Foundation
import Darwin

enum RoutingTable {

    /// Build a human-readable multi-section dump: interfaces, IPv4
    /// routes, IPv6 routes.
    static func dump(label: String) -> String {
        var out = "===== \(label) =====\n"
        out += "--- interfaces (getifaddrs) ---\n"
        out += dumpInterfaces()
        out += "--- IPv4 routes (sysctl NET_RT_DUMP AF_INET) ---\n"
        out += dumpRoutes(family: AF_INET)
        out += "--- IPv6 routes (sysctl NET_RT_DUMP AF_INET6) ---\n"
        out += dumpRoutes(family: AF_INET6)
        return out
    }

    // MARK: - getifaddrs

    private static func dumpInterfaces() -> String {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else {
            return "  (getifaddrs failed: errno=\(errno))\n"
        }
        defer { freeifaddrs(first) }

        var lines: [String] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let info = cur.pointee
            let name = String(cString: info.ifa_name)
            let familyStr: String
            let addrStr: String
            let netmaskStr: String
            if let sa = info.ifa_addr {
                familyStr = familyName(Int32(sa.pointee.sa_family))
                addrStr = sockaddrToString(sa) ?? ""
            } else {
                familyStr = "?"
                addrStr = ""
            }
            if let nm = info.ifa_netmask {
                netmaskStr = sockaddrToString(nm) ?? ""
            } else {
                netmaskStr = ""
            }
            let flagsStr = formatIfFlags(info.ifa_flags)
            lines.append("  \(name.padding(toLength: 10, withPad: " ", startingAt: 0))"
                         + " \(familyStr.padding(toLength: 5, withPad: " ", startingAt: 0))"
                         + " \(addrStr.padding(toLength: 40, withPad: " ", startingAt: 0))"
                         + " mask=\(netmaskStr.padding(toLength: 40, withPad: " ", startingAt: 0))"
                         + " flags=\(flagsStr)")
            ptr = info.ifa_next
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - sysctl NET_RT_DUMP

    private static func dumpRoutes(family: Int32) -> String {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, family, NET_RT_DUMP, 0]

        // Size query.
        var len: size_t = 0
        if sysctl(&mib, UInt32(mib.count), nil, &len, nil, 0) != 0 {
            return "  (sysctl size query failed: errno=\(errno))\n"
        }
        if len == 0 { return "  (no routes)\n" }

        // Fetch.
        var buf = [UInt8](repeating: 0, count: len)
        let rc = buf.withUnsafeMutableBufferPointer { bp -> Int32 in
            guard let base = bp.baseAddress else { return -1 }
            return sysctl(&mib, UInt32(mib.count), base, &len, nil, 0)
        }
        if rc != 0 {
            return "  (sysctl fetch failed: errno=\(errno))\n"
        }

        // Walk messages. All pointer reinterpretation stays local.
        var lines: [String] = []
        lines.append(String(format: "  %-40s %-40s %-10s %-10s %s",
                            "destination", "gateway", "iface", "flags", "rtax"))
        buf.withUnsafeBufferPointer { bp in
            guard let base = bp.baseAddress else { return }
            var offset = 0
            while offset < len {
                // Read msglen from the rt_msghdr header, staying inside
                // the rebind closure.
                let msglen: Int = base.advanced(by: offset)
                    .withMemoryRebound(to: rt_msghdr.self, capacity: 1) { ptr in
                        Int(ptr.pointee.rtm_msglen)
                    }
                if msglen == 0 { break }
                if offset + msglen > len { break }
                lines.append(formatRoute(base: base, offset: offset, msglen: msglen))
                offset += msglen
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func formatRoute(base: UnsafePointer<UInt8>,
                                    offset: Int,
                                    msglen: Int) -> String {
        // Copy out header fields (staying inside rebind closure).
        let (flags, addrs, ifIndex, hdrSize): (Int32, Int32, UInt16, Int) =
            base.advanced(by: offset).withMemoryRebound(to: rt_msghdr.self, capacity: 1) { ptr in
                (ptr.pointee.rtm_flags,
                 ptr.pointee.rtm_addrs,
                 ptr.pointee.rtm_index,
                 MemoryLayout<rt_msghdr>.size)
            }

        // Walk the sockaddr block immediately following the header.
        // Entries are ordered by RTAX_* and packed: each sockaddr
        // rounds up to the next 4-byte boundary (SA_SIZE macro in
        // kernel sources).
        var saOffset = offset + hdrSize
        var extractedAddrs: [Int: String] = [:]
        for rtax in 0..<Int(RTAX_MAX) {
            let bit: Int32 = 1 << rtax
            if (addrs & bit) == 0 { continue }
            if saOffset >= offset + msglen { break }

            // Bounds-checked sa_len read.
            let saLen: Int = base.advanced(by: saOffset)
                .withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    Int(saPtr.pointee.sa_len)
                }
            if saLen == 0 {
                // An empty sockaddr still consumes 4 bytes in the stream.
                saOffset += MemoryLayout<UInt32>.size
                continue
            }
            if saOffset + saLen > offset + msglen { break }

            // Convert to string — also staying in rebind closure.
            let str: String? = base.advanced(by: saOffset)
                .withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    sockaddrToString(saPtr)
                }
            if let str = str {
                extractedAddrs[rtax] = str
            }
            // SA_SIZE alignment: round up to next 4 bytes, min 4.
            let padded = max(4, (saLen + 3) & ~3)
            saOffset += padded
        }

        let dst = extractedAddrs[Int(RTAX_DST)] ?? "-"
        let gw = extractedAddrs[Int(RTAX_GATEWAY)] ?? "-"
        let mask = extractedAddrs[Int(RTAX_NETMASK)] ?? ""
        let dstCidr: String
        if mask.isEmpty {
            dstCidr = dst
        } else {
            dstCidr = "\(dst)/\(mask)"
        }
        let iface = interfaceName(forIndex: Int32(ifIndex)) ?? "if\(ifIndex)"
        let flagsStr = formatRouteFlags(flags)
        let addrsDesc = extractedAddrs.keys.sorted().map { rtaxName($0) }.joined(separator: ",")
        return String(format: "  %-40s %-40s %-10s %-10s %s",
                      dstCidr, gw, iface, flagsStr, addrsDesc)
    }

    // MARK: - sockaddr → string (pointer stays local)

    private static func sockaddrToString(_ sa: UnsafePointer<sockaddr>) -> String? {
        let family = Int32(sa.pointee.sa_family)

        switch family {
        case AF_INET:
            return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inptr in
                var addr = inptr.pointee.sin_addr
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                    return String(cString: buf)
                }
                return nil
            }

        case AF_INET6:
            return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { in6ptr in
                var addr = in6ptr.pointee.sin6_addr
                var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if inet_ntop(AF_INET6, &addr, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil {
                    return String(cString: buf)
                }
                return nil
            }

        case AF_LINK:
            return sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dlPtr in
                let dl = dlPtr.pointee
                let nameLen = Int(dl.sdl_nlen)
                let addrLen = Int(dl.sdl_alen)
                let index = Int(dl.sdl_index)

                // sdl_data holds nameLen bytes of interface name then
                // addrLen bytes of link-layer address (no separator).
                var name = ""
                if nameLen > 0 {
                    let nameBytes: [UInt8] = withUnsafePointer(to: dl.sdl_data) { dataPtr in
                        dataPtr.withMemoryRebound(to: UInt8.self, capacity: nameLen + addrLen) { bp in
                            Array(UnsafeBufferPointer(start: bp, count: nameLen))
                        }
                    }
                    name = String(bytes: nameBytes, encoding: .ascii) ?? ""
                }
                if addrLen == 0 {
                    return "link#\(index)\(name.isEmpty ? "" : "(\(name))")"
                }
                let addrBytes: [UInt8] = withUnsafePointer(to: dl.sdl_data) { dataPtr in
                    dataPtr.withMemoryRebound(to: UInt8.self, capacity: nameLen + addrLen) { bp in
                        Array(UnsafeBufferPointer(start: bp.advanced(by: nameLen), count: addrLen))
                    }
                }
                let hex = addrBytes.map { String(format: "%02x", $0) }.joined(separator: ":")
                return "\(name.isEmpty ? "link#\(index)" : name):\(hex)"
            }

        default:
            return "af=\(family)"
        }
    }

    // MARK: - Helpers: flags formatting

    /// Mimic netstat's route-flag short letters. See `<net/route.h>`.
    private static func formatRouteFlags(_ flags: Int32) -> String {
        var s = ""
        if flags & RTF_UP != 0        { s += "U" }
        if flags & RTF_GATEWAY != 0   { s += "G" }
        if flags & RTF_HOST != 0      { s += "H" }
        if flags & RTF_STATIC != 0    { s += "S" }
        if flags & RTF_DYNAMIC != 0   { s += "D" }
        if flags & RTF_LLINFO != 0    { s += "L" }
        if flags & RTF_CLONING != 0   { s += "C" }
        if flags & RTF_LOCAL != 0     { s += "l" }
        if flags & RTF_BROADCAST != 0 { s += "b" }
        if flags & RTF_MULTICAST != 0 { s += "m" }
        if flags & RTF_WASCLONED != 0 { s += "W" }
        if flags & RTF_IFSCOPE != 0   { s += "I" }
        // RTF_ROUTER = 0x80000000 comes in as UInt32 from BridgingHeader.h;
        // `flags` is Int32, so convert explicitly.
        if flags & Int32(bitPattern: RTF_ROUTER) != 0 { s += "R" }
        return s
    }

    private static func formatIfFlags(_ flags: UInt32) -> String {
        var parts: [String] = []
        if flags & UInt32(IFF_UP) != 0 { parts.append("UP") }
        if flags & UInt32(IFF_LOOPBACK) != 0 { parts.append("LOOPBACK") }
        if flags & UInt32(IFF_POINTOPOINT) != 0 { parts.append("P2P") }
        if flags & UInt32(IFF_RUNNING) != 0 { parts.append("RUNNING") }
        if flags & UInt32(IFF_MULTICAST) != 0 { parts.append("MCAST") }
        return parts.joined(separator: ",")
    }

    private static func familyName(_ family: Int32) -> String {
        switch family {
        case AF_INET: return "inet"
        case AF_INET6: return "inet6"
        case AF_LINK: return "link"
        default: return "af\(family)"
        }
    }

    private static func rtaxName(_ rtax: Int) -> String {
        switch Int32(rtax) {
        case RTAX_DST: return "DST"
        case RTAX_GATEWAY: return "GW"
        case RTAX_NETMASK: return "MASK"
        case RTAX_GENMASK: return "GENMASK"
        case RTAX_IFP: return "IFP"
        case RTAX_IFA: return "IFA"
        case RTAX_AUTHOR: return "AUTHOR"
        case RTAX_BRD: return "BRD"
        default: return "RTAX\(rtax)"
        }
    }

    private static func interfaceName(forIndex index: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        if if_indextoname(UInt32(index), &buf) != nil {
            return String(cString: buf)
        }
        return nil
    }
}
