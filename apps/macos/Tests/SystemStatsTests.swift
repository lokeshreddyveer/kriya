import XCTest
@testable import Kriya

final class SystemStatsTests: XCTestCase {
    func testCPUUsageBetweenReads() {
        let a = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let b = CPUTicks(user: 200, system: 100, idle: 1700, nice: 0)
        XCTAssertEqual(CPUTicks.usage(from: a, to: b), 150.0 / 1000.0 / 1.0 * 1.0 + 0.0, accuracy: 0.2)
        XCTAssertEqual(CPUTicks.usage(from: a, to: a), 0)
    }

    func testNetworkRateIgnoresBackwardsCounters() {
        let old = NetCounters(received: 1000, sent: 500)
        let new = NetCounters(received: 3000, sent: 400)
        let rate = NetCounters.rate(from: old, to: new, seconds: 2)
        XCTAssertEqual(rate.down, 1000)
        XCTAssertEqual(rate.up, 0)
    }

    func testByteFormatting() {
        XCTAssertEqual(ByteFormat.size(512), "512 B")
        XCTAssertEqual(ByteFormat.size(1536 * 1024), "1.5 MB")
        XCTAssertEqual(ByteFormat.duration(3 * 86_400 + 4 * 3600), "3 d 4 h")
        XCTAssertEqual(ByteFormat.duration(125 * 60), "2 h 05 m")
    }

    func testProgramsParse() {
        let list = ProcessUse.parse("  123  4.5  2048 Safari\n  9 0.0 100 Some App\nbad line\n")
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].name, "Safari")
        XCTAssertEqual(list[0].memory, 2048 * 1024)
        XCTAssertEqual(list[1].name, "Some App")
    }

    func testMenuBarText() {
        var s = MonitorSnapshot()
        s.cpu = 0.42
        s.memory = MemoryInfo(total: 100, used: 50)
        XCTAssertEqual(s.menuBarText([.cpu, .memory]), "CPU 42%  RAM 50%")
        XCTAssertEqual(MonitorMetric.parse("cpu,bogus,disk"), [.cpu, .disk])
    }
}

final class SystemToolsTests: XCTestCase {
    func testRequestsAreParsed() {
        XCTAssertEqual(SystemRequest.parse("kill Chrome"), .kill("chrome"))
        XCTAssertEqual(SystemRequest.parse("port 3000"), .port(3000))
        XCTAssertNil(SystemRequest.parse("port 99999"))
        XCTAssertEqual(SystemRequest.parse("wifi off"), .wifi(false))
        XCTAssertEqual(SystemRequest.parse("quit all"), .quitOthers)
        XCTAssertEqual(SystemRequest.parse("eject"), .eject)
        XCTAssertNil(SystemRequest.parse("quit safari"))
        XCTAssertNil(SystemRequest.parse("hello"))
    }

    func testPortOwnersParse() {
        XCTAssertEqual(PortOwner.parse("p123\ncnode\np123\ncnode\np9\ncpython\n"), [PortOwner(pid: 123, name: "node"), PortOwner(pid: 9, name: "python")])
    }

    func testLowBatteryWarnsOnceUntilCharged() {
        let low = [BatteryReading(name: "Magic Mouse", percent: 10, charging: false)]
        let first = LowBattery.check(low, warned: [])
        XCTAssertEqual(first.warn, ["Magic Mouse"])
        XCTAssertTrue(LowBattery.check(low, warned: first.warned).warn.isEmpty)
        let charged = LowBattery.check([BatteryReading(name: "Magic Mouse", percent: 80, charging: false)], warned: first.warned)
        XCTAssertTrue(charged.warned.isEmpty)
        XCTAssertEqual(LowBattery.check(low, warned: charged.warned).warn, ["Magic Mouse"])
    }

    func testMoreTextFilters() {
        XCTAssertEqual(TextFilter.jsonCompact.apply(to: "{ \"a\": 1,\n \"b\": [1, 2] }"), "{\"a\":1,\"b\":[1,2]}")
        XCTAssertTrue(TextFilter.jsonPretty.apply(to: "{\"a\":1}").contains("\n"))
        XCTAssertEqual(TextFilter.jsonPretty.apply(to: "not json"), "not json")
        XCTAssertEqual(TextFilter.base64Decode.apply(to: TextFilter.base64Encode.apply(to: "héllo")), "héllo")
        XCTAssertEqual(TextFilter.urlDecode.apply(to: TextFilter.urlEncode.apply(to: "a b&c")), "a b&c")
        XCTAssertEqual(TextFilter.snake.apply(to: "helloWorld fooBar"), "hello_world_foo_bar")
        XCTAssertEqual(TextFilter.kebab.apply(to: "Hello World"), "hello-world")
        XCTAssertEqual(TextFilter.camel.apply(to: "hello big_world"), "helloBigWorld")
    }

    func testFolderSizeIsMeasured() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kriya-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 1, count: 200_000).write(to: dir.appendingPathComponent("a.bin"))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(StorageScanner.size(of: dir)), 200_000)
    }
}
