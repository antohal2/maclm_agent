import Observation

@MainActor @Observable
final class PetRuntime {
    var hideContent = false
    var state = PetState.idle
    var paused = true
    var reduceMotion = false
    var scale = 2
}
