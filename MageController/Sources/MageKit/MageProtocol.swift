// 厂商协议帧编解码（逆向自 FIIO Control 网页版，实测通过）
//
// 帧格式: [HEAD][START][seqHi][seqLo][cmd][len][payload...][crc8][0xEE]
//   HEAD: 0xAA=设置 / 0xBB=查询    START: 0x0A / 0x0B

import Foundation

public enum MageProtocol {
    public static let setHead: UInt8 = 0xAA
    public static let getHead: UInt8 = 0xBB
    public static let setStart: UInt8 = 0x0A
    public static let getStart: UInt8 = 0x0B
    public static let stop: UInt8 = 0xEE

    public enum Cmd: UInt8, CaseIterable, Sendable {
        case volMax = 1
        case volOutput = 2
        case filterMode = 4
        case ledLight = 6
        case volBalance = 7
        case volOutputSwitch = 8
        case micSwitch = 18
        case peqParams = 21
        case peqPre = 22
        case peqSwitch = 26
        case resetFactory = 33
        case micVol = 34
        case ledCtrl = 51
        case micNrLevel = 52
        case gain3d = 53
        case reverbLevel = 54
        case channel71Config = 55
        case channel71Switch = 56
        case channel71Gain = 58
        case deviceName = 49
    }

    // 自定义 CRC-8 表（与飞傲网页版一致）
    static let crcTable: [UInt8] = [
        0,94,188,226,97,63,221,131,194,156,126,32,163,253,31,65,
        157,195,33,127,252,162,64,30,95,1,227,189,62,96,130,220,
        35,125,159,193,66,28,254,160,225,191,93,3,128,222,60,98,
        190,224,2,92,223,129,99,61,124,34,192,158,29,67,161,255,
        70,24,250,164,39,121,155,197,132,218,56,102,229,187,89,7,
        219,133,103,57,186,228,6,88,25,71,165,251,120,38,196,154,
        101,59,217,135,4,90,184,230,167,249,27,69,198,152,122,36,
        248,166,68,26,153,199,37,123,58,100,134,216,91,5,231,185,
        140,210,48,110,237,179,81,15,78,16,242,172,47,113,147,205,
        17,79,173,243,112,46,204,146,211,141,111,49,178,236,14,80,
        175,241,19,77,206,144,114,44,109,51,209,143,12,82,176,238,
        50,108,142,208,83,13,239,177,240,174,76,18,145,207,45,115,
        202,148,118,40,171,245,23,73,8,86,180,234,105,55,213,139,
        87,9,235,181,54,104,138,212,149,203,41,119,244,170,72,22,
        233,183,85,11,136,214,52,106,43,117,151,201,74,20,246,168,
        116,42,200,150,21,75,169,247,182,232,10,84,215,137,107,53]

    public static func crc8(_ data: [UInt8]) -> UInt8 {
        var t: UInt8 = 0
        for b in data { t = crcTable[Int((t ^ b) & 255)] }
        return t
    }

    public struct Frame: Equatable {
        public let head: UInt8
        public let start: UInt8
        public let sequence: UInt16
        public let cmd: UInt8
        public let payload: [UInt8]
    }

    private static var seq: UInt16 = 0
    private static let seqLock = NSLock()

    public static func resetSeq() {
        seqLock.lock()
        seq = 0
        seqLock.unlock()
    }

    public static func makeFrame(head: UInt8, start: UInt8, cmd: UInt8,
                                 payload: [UInt8]) -> [UInt8] {
        seqLock.lock()
        let s = seq
        seq &+= 1
        seqLock.unlock()
        var body = [head, start, UInt8((s >> 8) & 255), UInt8(s & 255),
                    cmd, UInt8(payload.count)] + payload
        body.append(crc8(body))
        body.append(stop)
        return body
    }

    /// 从原始 report 中解析出一个完整帧（到第一个 0xEE 为止）。
    /// 保留序号，供请求-响应通道避免把迟到回包交给下一次请求。
    public static func parseDetailedFrame(_ bytes: [UInt8]) -> Frame? {
        guard let headIndex = bytes.firstIndex(where: { $0 == setHead || $0 == getHead }),
              bytes.count > headIndex + 5 else { return nil }
        let len = Int(bytes[headIndex + 5])
        let end = headIndex + 6 + len + 1 // data + crc + ee
        guard bytes.count > end, bytes[end] == stop else { return nil }
        let bodyEnd = headIndex + 5 + len
        let body = Array(bytes[headIndex...bodyEnd])
        guard bytes[headIndex + 6 + len] == crc8(body) else { return nil }
        let payload = len == 0
            ? []
            : Array(bytes[(headIndex + 6)..<(headIndex + 6 + len)])
        return Frame(
            head: bytes[headIndex],
            start: bytes[headIndex + 1],
            sequence: UInt16(bytes[headIndex + 2]) << 8 | UInt16(bytes[headIndex + 3]),
            cmd: bytes[headIndex + 4],
            payload: payload
        )
    }

    /// 从原始 report 中解析出命令和 payload。
    public static func parseFrame(_ bytes: [UInt8]) -> (cmd: UInt8, payload: [UInt8])? {
        guard let frame = parseDetailedFrame(bytes) else { return nil }
        return (frame.cmd, frame.payload)
    }
}
