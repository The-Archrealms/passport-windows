namespace ArchrealmsPassport.HostedServices;

public sealed class PassportHostedRateLimiter
{
    private readonly object gate = new();
    private readonly Dictionary<string, Queue<DateTimeOffset>> requestWindows = new(StringComparer.Ordinal);

    public PassportHostedRateLimitResult Check(string key, int maxRequests, TimeSpan window)
    {
        if (string.IsNullOrWhiteSpace(key))
        {
            key = "anonymous";
        }

        if (maxRequests <= 0 || window <= TimeSpan.Zero)
        {
            return PassportHostedRateLimitResult.Success(maxRequests, window);
        }

        var now = DateTimeOffset.UtcNow;
        var cutoff = now.Subtract(window);
        lock (gate)
        {
            if (!requestWindows.TryGetValue(key, out var requests))
            {
                requests = new Queue<DateTimeOffset>();
                requestWindows[key] = requests;
            }

            while (requests.Count > 0 && requests.Peek() <= cutoff)
            {
                requests.Dequeue();
            }

            if (requests.Count >= maxRequests)
            {
                var retryAfter = requests.Peek().Add(window) - now;
                return PassportHostedRateLimitResult.Limited(maxRequests, window, retryAfter <= TimeSpan.Zero ? TimeSpan.FromSeconds(1) : retryAfter);
            }

            requests.Enqueue(now);
            return PassportHostedRateLimitResult.Success(maxRequests, window);
        }
    }
}

public sealed record PassportHostedRateLimitResult(
    bool Succeeded,
    string Message,
    int MaxRequests,
    TimeSpan Window,
    TimeSpan RetryAfter)
{
    public static PassportHostedRateLimitResult Success(int maxRequests, TimeSpan window)
    {
        return new PassportHostedRateLimitResult(true, "Rate limit accepted.", maxRequests, window, TimeSpan.Zero);
    }

    public static PassportHostedRateLimitResult Limited(int maxRequests, TimeSpan window, TimeSpan retryAfter)
    {
        return new PassportHostedRateLimitResult(false, "Hosted service rate limit exceeded.", maxRequests, window, retryAfter);
    }
}
