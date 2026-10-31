namespace Nephos.Faces.Api;

public static class Clustering
{
    public static double Similarity(float[] left, float[] right)
    {
        if (left.Length != 128 || right.Length != 128) return -1;
        double dot = 0, a = 0, b = 0;
        for (var i = 0; i < left.Length; i++)
        {
            if (!float.IsFinite(left[i]) || !float.IsFinite(right[i])) return -1;
            dot += left[i] * right[i]; a += left[i] * left[i]; b += right[i] * right[i];
        }
        return a > 0 && b > 0 ? dot / Math.Sqrt(a * b) : -1;
    }

    public static double Intersection(double x, double y, double w, double h, Detection face)
    {
        var area = Math.Max(0, Math.Min(x + w, face.X + face.Width) - Math.Max(x, face.X)) *
                   Math.Max(0, Math.Min(y + h, face.Y + face.Height) - Math.Max(y, face.Y));
        return area / (w * h + face.Width * face.Height - area);
    }

    public static void Validate(InferenceResult result, FaceJob job)
    {
        if (job.PipelineVersion != Pipeline.Version || result.ModelVersion != Pipeline.Model ||
            result.PreprocessVersion != Pipeline.Preprocess || result.SourceSha256 != job.SourceSha256 ||
            result.CoordinateSpace != "exif-normalized" || result.Width <= 0 || result.Height <= 0 ||
            (long)result.Width * result.Height > 64_000_000 || result.Faces.Length > 64)
            throw new InvalidDataException("invalid_provenance");
        foreach (var face in result.Faces)
        {
            if (!double.IsFinite(face.X + face.Y + face.Width + face.Height + face.Confidence) ||
                face.X < 0 || face.Y < 0 || face.Width <= 0 || face.Height <= 0 ||
                face.X + face.Width > 1.00001 || face.Y + face.Height > 1.00001 ||
                face.Confidence is < 0.9 or > 1 || face.Quality is not ("usable" or "too_small") ||
                (face.Quality == "usable") != (face.Embedding is not null) ||
                (face.Embedding is { } e && Similarity(e, e) < 0.999))
                throw new InvalidDataException("invalid_detection");
        }
    }
}
