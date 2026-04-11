//
//  pushupTests.swift
//  pushupTests
//
//  Created by Victor Deleeck on 11/04/2026.
//

import CoreGraphics
import Testing
@testable import pushup

struct pushupTests {

    @Test func repBankCalculatesRemainingRepCoins() async throws {
        let bank = RepBank(totalReps: 12, spentReps: 5, unlockedMinutes: 15)

        #expect(bank.repCoins == 7)
    }

    @Test func repBankNeverReturnsNegativeRepCoins() async throws {
        let bank = RepBank(totalReps: 2, spentReps: 30, unlockedMinutes: 60)

        #expect(bank.repCoins == 0)
    }

    @Test func repBankFlagsOffersThatExceedBalance() async throws {
        let bank = RepBank(totalReps: 9, spentReps: 4, unlockedMinutes: 15)
        let affordableOffer = RepBank.Offer(minutes: 15, repCost: 5)
        let expensiveOffer = RepBank.Offer(minutes: 60, repCost: 20)

        #expect(bank.canRedeem(affordableOffer) == true)
        #expect(bank.canRedeem(expensiveOffer) == false)
    }

    @MainActor
    @Test func repDetectorCountsDownThenUpSequence() async throws {
        var detector = PushupRepDetector()

        for _ in 0..<12 {
            _ = detector.process(faceArea: 0.10)
        }
        detector.advanceCalibrationIfNeeded()

        let goingDown = detector.process(faceArea: 0.14)
        #expect(goingDown.didCompleteRep == false)

        let lowered = detector.process(faceArea: 0.16)
        #expect(lowered.didCompleteRep == false)

        let completed = detector.process(faceArea: 0.10)
        #expect(completed.didCompleteRep == true)
    }

    @MainActor
    @Test func repDetectorResetsWhenFaceDisappears() async throws {
        var detector = PushupRepDetector()

        for _ in 0..<12 {
            _ = detector.process(faceArea: 0.10)
        }
        detector.advanceCalibrationIfNeeded()

        let lostFace = detector.process(faceArea: nil)

        #expect(lostFace.faceDetected == false)
        #expect(detector.phase == .calibrating)
    }

}
