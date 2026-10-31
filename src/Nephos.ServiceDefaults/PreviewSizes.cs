namespace Nephos.ServiceDefaults;

public static class PreviewSizes
{
    public static readonly int[] All = [512, 1280, 2560];
    public static bool Supports(int size) => size is 512 or 1280 or 2560;
}
