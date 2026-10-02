import CoreGraphics
import Testing
@testable import Unrager

@Suite("Profile banner motion")
struct ProfileBannerMotionTests {
    private func motion(_ scroll: CGFloat) -> ProfileBannerMotion {
        ProfileBannerMotion.at(scroll: scroll, safeTop: 100, visible: 96)
    }

    @Test("At rest the image fills the bar and the banner, untouched")
    func atRest() {
        let rest = motion(0)
        #expect(rest.y == 0)
        #expect(rest.height == 196)
        #expect(rest.blur == 0 && rest.dim == 0 && rest.zoom == 0)
        #expect(rest.avatarScale == 1 && rest.avatarAlpha == 1)
    }

    @Test("Pulling down stretches the image from the top and nothing else moves")
    func pullStretches() {
        let pulled = motion(-80)
        #expect(pulled.y == 0)
        #expect(pulled.height == 276)
        #expect(pulled.blur == 0 && pulled.avatarScale == 1)
    }

    @Test("Scrolling up drifts the image at half speed under a profile that moves at full speed")
    func scrollParallax() {
        let moved = motion(60)
        #expect(moved.y == -30)
        #expect(moved.height == 196)
    }

    @Test("Blur, dim and zoom only grow as the profile covers the image, and top out")
    func recedesMonotonically() {
        var previous = motion(0)
        for scroll in stride(from: CGFloat(10), through: 400, by: 10) {
            let next = motion(scroll)
            #expect(next.blur >= previous.blur)
            #expect(next.dim >= previous.dim)
            #expect(next.zoom >= previous.zoom)
            #expect(next.avatarScale <= previous.avatarScale)
            #expect(next.avatarAlpha <= previous.avatarAlpha)
            previous = next
        }
        #expect(previous.blur == 1)
        #expect(abs(previous.dim - ProfileBannerMotion.dimmest) < 0.0001)
        #expect(previous.avatarScale == ProfileBannerMotion.avatarMinimumScale)
        #expect(previous.avatarAlpha == 0)
    }

    @Test("The same offset always gives the same motion, so scrolling back replays it")
    func reversible() {
        #expect(motion(70) == motion(70))
        let down = (0...7).map { motion(CGFloat($0) * 20) }
        let back = (0...7).reversed().map { motion(CGFloat($0) * 20) }
        #expect(down == back.reversed())
    }

    @Test("The bar's title appears only once the name has scrolled under it")
    func titleAppearsAfterTheName() {
        #expect(ProfileBannerMotion.titleAlpha(scroll: 0, nameBottom: 180) == 0)
        #expect(ProfileBannerMotion.titleAlpha(scroll: 150, nameBottom: 180) == 0)
        #expect(ProfileBannerMotion.titleAlpha(scroll: 180, nameBottom: 180) > 0.4)
        #expect(ProfileBannerMotion.titleAlpha(scroll: 220, nameBottom: 180) == 1)
    }
}
