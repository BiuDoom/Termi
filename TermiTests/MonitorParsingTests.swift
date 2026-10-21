import Testing
import Foundation
@testable import Termi

// MARK: - Memory Parsing

@Test func parseMemoryLinux() async {
    let monitor = MonitorService()
    let raw = """
                  total        used        free      shared  buff/cache   available
    Mem:    16777216000  8388608000  4194304000   104857600  4194304000  8000000000
    Swap:    2147483648           0  2147483648
    """

    var stats = MonitorService.ServerStats()
    await monitor.parseMemory(raw, stats: &stats)

    #expect(stats.memTotal == 16_777_216_000)
    #expect(stats.memUsed == 8_388_608_000)
    #expect(stats.memPercent > 49.0 && stats.memPercent < 51.0) // ~50%
}

@Test func parseMemoryEmpty() async {
    let monitor = MonitorService()
    var stats = MonitorService.ServerStats()
    await monitor.parseMemory("", stats: &stats)

    #expect(stats.memTotal == 0)
    #expect(stats.memUsed == 0)
    #expect(stats.memPercent == 0)
}

// MARK: - Disk Parsing

@Test func parseDiskLinux() async {
    let monitor = MonitorService()
    let raw = """
    Filesystem     1B-blocks       Used  Available Use% Mounted on
    /dev/sda1   107374182400 53687091200 53687091200  50% /
    """

    var stats = MonitorService.ServerStats()
    await monitor.parseDisk(raw, stats: &stats)

    #expect(stats.diskTotal == 107_374_182_400)
    #expect(stats.diskUsed == 53_687_091_200)
    #expect(stats.diskPercent > 49.0 && stats.diskPercent < 51.0)
}

@Test func parseDiskEmpty() async {
    let monitor = MonitorService()
    var stats = MonitorService.ServerStats()
    await monitor.parseDisk("", stats: &stats)

    #expect(stats.diskTotal == 0)
    #expect(stats.diskUsed == 0)
}

// MARK: - CPU Parsing

@Test func parseCPULinux() async {
    let monitor = MonitorService()
    let raw = """
    top - 10:30:00 up 5 days,  3:22,  2 users,  load average: 0.50, 0.35, 0.20
    Tasks: 234 total,   1 running, 233 sleeping,   0 stopped,   0 zombie
    %Cpu(s):  5.3 us,  2.1 sy,  0.0 ni, 91.5 id,  0.7 wa,  0.0 hi,  0.4 si,  0.0 st
    """

    var stats = MonitorService.ServerStats()
    await monitor.parseCPU(raw, stats: &stats)

    // idle = 91.5, so usage = 100 - 91.5 = 8.5
    #expect(stats.cpuUsage > 8.0 && stats.cpuUsage < 9.0)
    #expect(stats.processes == 234)
}

@Test func parseCPUEmpty() async {
    let monitor = MonitorService()
    var stats = MonitorService.ServerStats()
    await monitor.parseCPU("", stats: &stats)

    #expect(stats.cpuUsage == 0)
    #expect(stats.processes == 0)
}

// MARK: - Network Parsing

@Test func parseNetworkLinux() async {
    let monitor = MonitorService()
    let raw = """
    eth0: 1000000 100 0 0 0 0 0 0 2000000 200 0 0 0 0 0 0
    lo:   500000  50 0 0 0 0 0 0  500000  50 0 0 0 0 0 0
    """

    var stats = MonitorService.ServerStats()
    await monitor.parseNetwork(raw, stats: &stats)

    #expect(stats.networkRx == 1_500_000) // 1000000 + 500000
    #expect(stats.networkTx == 2_500_000) // 2000000 + 500000
}

@Test func parseNetworkEmpty() async {
    let monitor = MonitorService()
    var stats = MonitorService.ServerStats()
    await monitor.parseNetwork("", stats: &stats)

    #expect(stats.networkRx == 0)
    #expect(stats.networkTx == 0)
}

// MARK: - Full parseStats

@Test func parseStatsComplete() async {
    let monitor = MonitorService()
    let output = """
    ===HOSTNAME===
    prod-server-01
    ===UPTIME===
     10:30:00 up 5 days,  3:22,  2 users,  load average: 1.50, 0.80, 0.30
    ===LOADAVG===
    1.50 0.80 0.30 2/234 12345
    ===MEM===
                  total        used        free      shared  buff/cache   available
    Mem:    16777216000  8388608000  4194304000   104857600  4194304000  8000000000
    ===DISK===
    Filesystem     1B-blocks       Used  Available Use% Mounted on
    /dev/sda1   107374182400 53687091200 53687091200  50% /
    ===CPU===
    top - 10:30:00 up 5 days
    Tasks: 200 total
    %Cpu(s):  10.0 us,  5.0 sy,  0.0 ni, 85.0 id
    ===NET===
    eth0: 1000 10 0 0 0 0 0 0 2000 20 0 0 0 0 0 0
    """

    let stats = await monitor.parseStats(output)

    #expect(stats.hostname == "prod-server-01")
    #expect(stats.loadAvg1 == 1.50)
    #expect(stats.loadAvg5 == 0.80)
    #expect(stats.loadAvg15 == 0.30)
    #expect(stats.memTotal == 16_777_216_000)
    #expect(stats.diskTotal == 107_374_182_400)
    #expect(stats.networkRx == 1000)
    #expect(stats.networkTx == 2000)
}
