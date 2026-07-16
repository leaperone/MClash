import Darwin
import Testing

@main
struct MClashTestRunner {
    static func main() async {
        let status: CInt = await Testing.__swiftPMEntryPoint()
        exit(status)
    }
}
