import Dispatch
import Metal
import Testing
@testable import InkTerminalView

@Suite("TerminalRenderer 完成回调")
struct TerminalRendererTests {
    @Test("Metal 驱动队列可以释放三缓冲信号量")
    func completionQueueCanSignalInflightSemaphore() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let commands = try #require(queue.makeCommandBuffer())
        let inflight = DispatchSemaphore(value: 0)

        commands.addCompletedHandler(MetalCommandCompletion.signal(inflight))
        commands.commit()

        #expect(inflight.wait(timeout: .now() + 5) == .success)
    }
}
