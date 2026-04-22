//
//  RoutingTable.swift
//  RoutingDiag / Extension
//
//  Two diagnostics, both using only documented-ish BSD APIs that
//  work in iOS Network Extensions without special entitlements:
//
//  1. `dumpInterfaces()` — `getifaddrs(3)`, the standard way to list
//     interface names / addresses / flags. Fully public API.
//
//  2. `dumpIPv4Routes()` / `dumpIPv6Routes()` —
//     `sysctl(CTL_NET, PF_ROUTE, 0, AF_INET|AF_INET6, NET_RT_DUMP, 0)`,
//     the same way `netstat -rn` queries the kernel on macOS/iOS.
//     The API itself is public (declared in `<sys/sysctl.h>` /
//     `<net/route.h>`), though iOS App Store review has historically
//     been variable about routing-table dumps. For dev builds /
//     TestFlight this is fine.
//
//  All helpers return ready-to-log strings rather than structured
//  data — we don't need to programmatically manipulate the routes,
//  only to diff two dumps by eye.
//

import Foundation
import Darwin

enum RoutingTable {

    /// Build a human-readable string of the current kernel state:
    /// interfaces, IPv4 routing table, IPv6 routing table.
    static func dump(label: String) -> String {
        var out = "===== \(label) =====\n"
        out += "--- interfaces (getifaddrs) ---\n"
        out += dumpInterfaces()
        out += "--- IPv4 routes (sysctl NET_RT_DUMP) ---\n"
        out += dumpRoutes(family: AF_INET)
        out += "--- IPv6 routes (sysctl NET_RT_DUMP) ---\n"
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
            var addrStr = ""
            var netmaskStr = ""
            if let sa = info.ifa_addr?.pointee {
                familyStr = familyName(Int32(sa.sa_family))
                addrStr = sockaddrToString(info.ifa_addr) ?? ""
            } else {
                familyStr = "?"
            }
            if let nm = info.ifa_netmask {
                netmaskStr = sockaddrToString(nm) ?? ""
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

        // 1. Ask for the size.
        var len: size_t = 0
        if sysctl(&mib, UInt32(mib.count), nil, &len, nil, 0) != 0 {
            return "  (sysctl size query failed: errno=\(errno))\n"
        }
        if len == 0 { return "  (no routes)\n" }

        // 2. Fetch.
        var buf = [UInt8](repeating: 0, count: len)
        let rc = buf.withUnsafeMutableBufferPointer { bp -> Int32 in
            guard let base = bp.baseAddress else { return -1 }
            return sysctl(&mib, UInt32(mib.count), base, &len, nil, 0)
        }
        if rc != 0 {
            return "  (sysctl fetch failed: errno=\(errno))\n"
        }

        // 3. Walk the buffer message-by-message.
        var lines: [String] = []
        lines.append(String(format: "  %-40s %-40s %-10s %-6s %s",
                            "destination", "gateway", "iface", "flags", "addrs"))
        var offset = 0
        buf.withUnsafeBufferPointer { bp in
            guard let base = bp.baseAddress else { return }
            while offset < len {
                let hdrPtr = base.advanced(by: offset)
                    .withMemoryRebound(to: rt_msghdr.self, capacity: 1) { $0 }
                let msglen = Int(hdrPtr.pointee.rtm_msglen)
                if msglen == 0 { break }
                lines.append(formatRoute(base: base, offset: offset, family: family))
                offset += msglen
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func formatRoute(base: UnsafePointer<UInt8>,
                                    offset: Int,
                                    family _: Int32) -> String {
        let hdr = base.advanced(by: offset)
            .withMemoryRebound(to: rt_msghdr.self, capacity: 1) { $0.pointee }
        let flags = hdr.rtm_flags
        let addrs = hdr.rtm_addrs
        let ifIndex = hdr.rtm_index

        // Sockaddr block starts immediately after the header. Entries
        // are ordered by RTAX_* and packed with sockaddr-specific
        // alignment: each sockaddr rounds up to the next 4-byte
        // boundary (SA_SIZE in kernel sources).
        var saOffset = offset + MemoryLayout<rt_msghdr>.size
        var extractedAddrs: [Int: String] = [:]
        for rtax in 0..<RTAX_MAX {
            let bit: Int32 = 1 << rtax
            if (addrs & bit) == 0 { continue }
            let saPtr = base.advanced(by: saOffset)
                .withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
            let saLen = Int(saPtr.pointee.sa_len)
            if saLen == 0 {
                saOffset += MemoryLayout<UInt32>.size
                continue
            }
            if let str = sockaddrToString(saPtr) {
                extractedAddrs[Int(rtax)] = str
            }
            // Align to the next 4-byte boundary.
            let padded = (saLen + 3) & ~3
            saOffset += padded
        }

        let dst = extractedAddrs[Int(RTAX_DST)] ?? "-"
        let gw = extractedAddrs[Int(RTAX_GATEWAY)] ?? "-"
        let mask = extractedAddrs[Int(RTAX_NETMASK)] ?? ""
        let dstCidr: String
        if mask.isEmpty || mask == "/0" {
            dstCidr = dst
        } else {
            dstCidr = "\(dst) \(mask)"
        }
        let iface = interfaceName(forIndex: Int32(ifIndex)) ?? "if\(ifIndex)"
        let flagsStr = formatRouteFlags(flags)
        // A debug hint: list which RTAX_ slots had data.
        let addrsDesc = extractedAddrs.keys.sorted().map { rtaxName($0) }.joined(separator: ",")
        return String(format: "  %-40s %-40s %-10s %-6s %s",
                      dstCidr, gw, iface, flagsStr, addrsDesc)
    }

    // MARK: - Helpers: sockaddr → string

    private static func sockaddrToString(_ sa: UnsafePointer<sockaddr>?) -> String? {
        guard let sa = sa else { return nil }
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
            // Data-link sockaddrs usually appear in RTAX_GATEWAY /
            // RTAX_IFP. We return the interface name when available
            // plus a hex dump of the link-level address if present.
            return sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dlPtr in
                let dl = dlPtr.pointee
                let nameLen = Int(dl.sdl_nlen)
                let addrLen = Int(dl.sdl_alen)
                var name = ""
                if nameLen > 0 {
                    withUnsafePointer(to: dl.sdl_data) { dataPtr in
                        dataPtr.withMemoryRebound(to: CChar.self, capacity: nameLen) { cptr in
                            name = String(cString: cptr, encoding: .ascii) ?? ""
                            // sdl_data is unterminated — clamp.
                            name = String(name.prefix(nameLen))
                        }
                    }
                }
                if addrLen == 0 {
                    return "link#\(dl.sdl_index)\(name.isEmpty ? "" : "(\(name))")"
                }
                // Link-layer address (e.g. MAC) hex dump.
                var hex = ""
                withUnsafePointer(to: dl.sdl_data) { dataPtr in
                    dataPtr.withMemoryRebound(to: UInt8.self, capacity: nameLen + addrLen) { bp in
                        for i in 0..<addrLen {
                            if i > 0 { hex += ":" }
                            hex += String(format: "%02x", bp.advanced(by: nameLen + i).pointee)
                        }
                    }
                }
                return "\(name.isEmpty ? "link" : name):\(hex)"
            }

        default:
            return "af=\(family)"
        }
    }

    // MARK: - Helpers: flags formatting

    /// Mimic netstat's route-flag short letters for the most common
    /// flags. See `<net/route.h>`.
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
