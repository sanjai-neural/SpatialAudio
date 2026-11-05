/// Step 3a (audio only, scripted head pose, no camera): `EnvironmentRenderer` (AVAudioEnvironmentNode + HRTFHQ),
/// `TestTone`, `ListenerPosePump`, `ListeningTestSession`. `AudioSource` / `SpatialRenderer` protocols are PLANNED
/// for when a second source or renderer exists (Step 6 / Step 8); with only one implementation they would be guesses.
public enum SpatialAudioEngine {
    public static let moduleName = "SpatialAudioEngine"
}
