//
//  RoutingWriter.swift
//  RoutingDiag / Extension
//
//  Attempts to WRITE to the kernel routing table via a raw
//  PF_ROUTE socket, the same BSD mechanism that `route add` /
//  `route delete` use on macOS. iOS ships this socket family
//  (we already read the table via `sysctl(NET_RT_DUMP, ...)`);
//  whether a Network Extension sandbox permits WRITING via it
//  is undocumented. This file is the empirical test.
//
//  Two operations exposed:
//
//    - `deleteScopedDefault(ifaceName:)` — RTM_DELETE for
//      `0.0.0.0 ... UGSI` scoped to a specific physical
//      interface. Target scenario: remove the scoped default
//      that iOS uses to send `apsd` / `CommCenter` traffic
//      out the physical interface, so kernel falls through
//      to the unscoped tunnel default.
//
//    - `addScopedRoute(dst:mask:gateway:scopeIfaceName:)` —
//      RTM_ADD for a route with the RTF_IFSCOPE flag set,
//      attempting to insert a 17.0.0.0/8 entry scoped to
//      `en0` whose gateway points at our tunnel IP, so
//      scoped lookup on en0 picks it over the scoped default.
//
//  Both return a structured `Result` — `rc`, `errno`, human
//  description — which the caller logs. For RTM_DELETE /
//  RTM_ADD the kernel processes the request synchronously
//  inside `write(2)` and reports success or failure via the
//  write return value, so we don't need to read the routing
//  socket to get the answer.
//

import Foundation
import Darwin

enum RoutingWriter {

    struct Result {
        let rc: Int              // write() return, or -1 before write
        let errnoValue: Int32    // errno captured right after write
        let details: String      // human readable summary
        var ok: Bool { rc > 0 }
    }

    // MARK: - Public entry points

    /// Attempt to delete the scoped IPv4 default route on `ifaceName`.
    /// Matches the `0.0.0.0 ... UGSI` entry whose `rtm_index` equals
    /// the interface index. `gateway` is ignored by the kernel when
    /// RTF_IFSCOPE + scope are set — matching is done by scope + dst.
    static func deleteScopedIPv4Default(ifaceName: String) -> Result {
        let ifindex = if_nametoindex(ifaceName)
        if ifindex == 0 {
            return Result(rc: -1, errnoValue: ENODEV,
                          details: "if_nametoindex(\(ifaceName)) returned 0")
        }
        guard let dst = makeSockaddrIn("0.0.0.0"),
              let mask = makeSockaddrIn("0.0.0.0") else {
            return Result(rc: -1, errnoValue: EINVAL,
                          details: "sockaddr construction failed")
        }
        let flags = Int32(RTF_STATIC) | Int32(bitPattern: UInt32(RTF_IFSCOPE))
        return sendRTM(
            type: UInt8(RTM_DELETE),
            flags: flags,
            scopeIfIndex: UInt16(ifindex),
            dst: dst, gateway: nil, mask: mask,
            description: "RTM_DELETE scoped-default iface=\(ifaceName) (idx=\(ifindex))")
    }

    /// Attempt to add a scoped IPv4 route for `dstCIDR` via
    /// `gatewayIPv4`, scoped to `scopeIfaceName`.
    /// e.g. addScopedIPv4Route(dst: "17.0.0.0", mask: "255.0.0.0",
    ///                         gateway: "10.200.0.4",
    ///                         scopeIfaceName: "en0")
    static func addScopedIPv4Route(
        dst dstStr: String,
        mask maskStr: String,
        gateway gatewayStr: String,
        scopeIfaceName: String
    ) -> Result {
        let ifindex = if_nametoindex(scopeIfaceName)
        if ifindex == 0 {
            return Result(rc: -1, errnoValue: ENODEV,
                          details: "if_nametoindex(\(scopeIfaceName)) returned 0")
        }
        guard let dst = makeSockaddrIn(dstStr),
              let mask = makeSockaddrIn(maskStr),
              let gw = makeSockaddrIn(gatewayStr) else {
            return Result(rc: -1, errnoValue: EINVAL,
                          details: "sockaddr construction failed")
        }
        let flags = Int32(RTF_UP) | Int32(RTF_STATIC) | Int32(RTF_GATEWAY)
                  | Int32(bitPattern: UInt32(RTF_IFSCOPE))
        return sendRTM(
            type: UInt8(RTM_ADD),
            flags: flags,
            scopeIfIndex: UInt16(ifindex),
            dst: dst, gateway: gw, mask: mask,
            description: "RTM_ADD \(dstStr)/\(maskStr) via \(gatewayStr) scoped to \(scopeIfaceName) (idx=\(ifindex))")
    }

    /// Sanity-check that we can at least OPEN a PF_ROUTE socket for
    /// writing. If this fails with EPERM / EACCES, all of the above
    /// is moot and we don't need to bother with the other tests.
    static func probeOpenRoutingSocket() -> Result {
        let sock = socket(PF_ROUTE, SOCK_RAW, 0)
        if sock < 0 {
            let e = errno
            return Result(rc: -1, errnoValue: e,
                          details: "socket(PF_ROUTE, SOCK_RAW, 0) failed: \(String(cString: strerror(e)))")
        }
        close(sock)
        return Result(rc: 1, errnoValue: 0,
                      details: "socket(PF_ROUTE, SOCK_RAW, 0) OK — process is allowed to open the routing socket")
    }

    // MARK: - Private plumbing

    private static func makeSockaddrIn(_ ipv4: String) -> sockaddr_in? {
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = 0
        let rc = ipv4.withCString { cstr in
            return inet_pton(AF_INET, cstr, &sin.sin_addr)
        }
        if rc != 1 { return nil }
        return sin
    }

    private static func sendRTM(
        type: UInt8,
        flags: Int32,
        scopeIfIndex: UInt16,
        dst: sockaddr_in,
        gateway: sockaddr_in?,
        mask: sockaddr_in?,
        description: String
    ) -> Result {
        let sock = socket(PF_ROUTE, SOCK_RAW, 0)
        if sock < 0 {
            let e = errno
            return Result(rc: -1, errnoValue: e,
                          details: "\(description): socket() failed: \(String(cString: strerror(e)))")
        }
        defer { close(sock) }

        let hdrSize = MemoryLayout<rt_msghdr>.size
        let saSize = MemoryLayout<sockaddr_in>.size   // already 4-byte aligned
        var rtmAddrs: Int32 = Int32(RTA_DST)
        var totalSize = hdrSize + saSize
        if gateway != nil {
            rtmAddrs |= Int32(RTA_GATEWAY)
            totalSize += saSize
        }
        if mask != nil {
            rtmAddrs |= Int32(RTA_NETMASK)
            totalSize += saSize
        }

        var buf = [UInt8](repeating: 0, count: totalSize)
        buf.withUnsafeMutableBytes { rawPtr in
            guard let base = rawPtr.baseAddress else { return }

            // Fill rt_msghdr.
            let hdrPtr = base.assumingMemoryBound(to: rt_msghdr.self)
            hdrPtr.pointee.rtm_msglen = UInt16(totalSize)
            hdrPtr.pointee.rtm_version = UInt8(RTM_VERSION)
            hdrPtr.pointee.rtm_type = type
            hdrPtr.pointee.rtm_index = scopeIfIndex
            hdrPtr.pointee.rtm_flags = flags
            hdrPtr.pointee.rtm_addrs = rtmAddrs
            hdrPtr.pointee.rtm_pid = 0
            hdrPtr.pointee.rtm_seq = 42
            hdrPtr.pointee.rtm_errno = 0
            hdrPtr.pointee.rtm_use = 0
            hdrPtr.pointee.rtm_inits = 0

            // Append sockaddrs after the header.
            // RTAX order: DST, GATEWAY, NETMASK.
            var off = hdrSize

            var sd = dst
            memcpy(base.advanced(by: off), &sd, saSize)
            off += saSize

            if var sg = gateway {
                memcpy(base.advanced(by: off), &sg, saSize)
                off += saSize
            }
            if var sm = mask {
                memcpy(base.advanced(by: off), &sm, saSize)
                off += saSize
            }
            _ = off
        }

        let written = buf.withUnsafeBufferPointer { bp -> Int in
            return write(sock, bp.baseAddress, totalSize)
        }
        let savedErrno = errno

        if written < 0 {
            return Result(
                rc: written, errnoValue: savedErrno,
                details: "\(description): write() failed: \(String(cString: strerror(savedErrno))) (errno=\(savedErrno))")
        }
        return Result(
            rc: written, errnoValue: 0,
            details: "\(description): write() OK, \(written)/\(totalSize) bytes accepted by kernel")
    }
}
