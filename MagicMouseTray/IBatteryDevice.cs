namespace MagicMouseTray;

public enum DeviceKind
{
    MagicMouseV1,
    MagicMouseV2,
    MagicMouseV3,
    MagicKeyboard,
}

public interface IBatteryDevice
{
    string DeviceName { get; }
    DeviceKind Kind { get; }

    /// <summary>
    /// Returns battery percentage (0–100), or a sentinel:
    ///   -1  device not found
    ///   -2  device present but descriptor blocks read (unified/Mode-B)
    /// </summary>
    int GetBatteryPercent();
}
