using System.Runtime.ExceptionServices;

namespace Tallow;

/// <summary>
/// Runs <c>await</c> continuations on the game thread. Installed while a game runs: code after an <c>await</c>
/// in a script (Task.Delay, file or web requests, <see cref="Script.NextFrame"/>, <see cref="Script.Wait"/>)
/// carries on once a frame, after LateUpdate, where it may use the engine as any callback does. When the game
/// stops, anything still waiting is dropped. <c>ConfigureAwait(false)</c> leaves the game thread: the engine
/// must not be used from there.
/// </summary>
internal sealed class GameSynchronizationContext : SynchronizationContext
{
    private readonly int _thread = Environment.CurrentManagedThreadId;
    private readonly object _lock = new();
    private List<(SendOrPostCallback Callback, object? State)> _queue = [], _running = [];
    private bool _closed;

    public bool OnGameThread => Environment.CurrentManagedThreadId == _thread;

    public override void Post(SendOrPostCallback callback, object? state)
    {
        lock (_lock)
        {
            if (!_closed)
                _queue.Add((callback, state));
        }
    }

    public override void Send(SendOrPostCallback callback, object? state)
    {
        if (!OnGameThread)
            throw new InvalidOperationException("Waiting for the game thread from another thread would stall it; use Post.");
        callback(state);
    }

    public override SynchronizationContext CreateCopy() => this;

    /// <summary>Runs what was posted before this call (anything posted meanwhile waits for the next frame).
    /// Every callback runs; the first exception, other than a cancellation, is returned.</summary>
    public Exception? Run()
    {
        lock (_lock)
            (_queue, _running) = (_running, _queue);
        Exception? first = null;
        foreach ((SendOrPostCallback callback, object? state) in _running)
        {
            try
            {
                callback(state);
            }
            catch (OperationCanceledException)
            {
                // An async void method stopped by its script's Destroyed token: the normal way for it to end.
            }
            catch (Exception exception)
            {
                first ??= exception;
            }
        }
        _running.Clear();
        return first;
    }

    /// <summary>Continuations posted and not yet run.</summary>
    public int Pending
    {
        get
        {
            lock (_lock)
                return _queue.Count;
        }
    }

    public void Close()
    {
        lock (_lock)
        {
            _closed = true;
            _queue.Clear();
        }
    }
}

/// <summary>The game thread's async state: the context, and the waits on game time.</summary>
internal static class GameThread
{
    internal sealed class Waiter(float remaining, long frame, CancellationToken token, string? owner)
    {
        public float Remaining = remaining;
        /// <summary>The script class that waits (Wait/NextFrame), for the hot reload's report.</summary>
        public readonly string? Owner = owner;
        public readonly long Frame = frame;
        public readonly TaskCompletionSource Done = new();
        public readonly CancellationToken Token = token;
        public CancellationTokenRegistration Registration;
    }

    private static GameSynchronizationContext? sContext;
    private static readonly List<Waiter> sWaiters = [];
    private static readonly List<Waiter> sFinished = [];
    /// <summary>Counts pumps: a wait started in frame N counts time and can end from frame N + 1 on.</summary>
    private static long sFrame;

    public static bool Running => sContext != null;

    /// <summary>Runs once a frame from <see cref="Pump"/>, before the continuations: API pieces that poll the
    /// engine for news (AntiCheat.OnViolation) hook in here. Cleared when the game stops.</summary>
    public static event Action? EachFrame;

    /// <summary>Called on the game thread when a game loads.</summary>
    public static void Start()
    {
        Stop();
        sContext = new GameSynchronizationContext();
        SynchronizationContext.SetSynchronizationContext(sContext);
    }

    /// <summary>The game ended: drop queued continuations and cancel game-time waits.</summary>
    public static void Stop()
    {
        if (sContext == null)
            return;
        sContext.Close();
        foreach (Waiter waiter in sWaiters.ToArray())
        {
            waiter.Registration.Dispose();
            waiter.Done.TrySetCanceled();
        }
        sWaiters.Clear();
        sFinished.Clear();
        EachFrame = null;
        if (SynchronizationContext.Current == sContext)
            SynchronizationContext.SetSynchronizationContext(null);
        sContext = null;
    }

    /// <summary>What a hot reload set aside: the old code's context and game-time waits.</summary>
    internal sealed class Detached
    {
        internal GameSynchronizationContext? Context;
        internal List<Waiter> Waiters = [];
        /// <summary>Full names of the script classes waiting on game time when the reload began, one per await
        /// (taken then: the old scripts' Destroyed tokens are cancelled as they move to the new code).</summary>
        internal List<string> Waiting = [];
        /// <summary>Continuations queued when the reload began.</summary>
        internal int Queued;
    }

    /// <summary>Hot reload, before the new code loads: sets the old code's continuations and waits aside and
    /// starts a fresh context (the hooks API pieces put on <see cref="EachFrame"/> stay: they are not game
    /// code). <see cref="Reattach"/> puts them back if the new code fails to load; <see cref="Drop"/> ends
    /// them once it loaded.</summary>
    internal static Detached Detach()
    {
        var detached = new Detached { Context = sContext, Queued = sContext?.Pending ?? 0 };
        detached.Waiters.AddRange(sWaiters);
        foreach (Waiter waiter in sWaiters)
        {
            if (!waiter.Token.IsCancellationRequested)
                detached.Waiting.Add(waiter.Owner ?? "");
        }
        sWaiters.Clear();
        sFinished.Clear();
        sContext = new GameSynchronizationContext();
        SynchronizationContext.SetSynchronizationContext(sContext);
        return detached;
    }

    /// <summary>The reload failed: the old code keeps running, with its waits.</summary>
    internal static void Reattach(Detached detached)
    {
        if (detached.Context == null)
            return;
        sContext?.Close();
        sContext = detached.Context;
        SynchronizationContext.SetSynchronizationContext(sContext);
        sWaiters.Clear();
        sWaiters.AddRange(detached.Waiters);
        detached.Context = null;
    }

    /// <summary>The reload worked: the old code's awaits can never carry on (their state belongs to code that is
    /// unloading), so they end without running: not cancelled, as a cancellation could run the old code's
    /// catch/finally blocks on objects that moved to the new code. See <see cref="Detached.Waiting"/>.</summary>
    internal static void Drop(Detached detached)
    {
        detached.Context?.Close();
        detached.Context = null;
        foreach (Waiter waiter in detached.Waiters)
            waiter.Registration.Dispose();
        detached.Waiters.Clear();
    }

    /// <summary>A wait of a number of seconds of game time (0: the next frame).</summary>
    public static Task Delay(float seconds, CancellationToken token, string? owner = null)
    {
        if (sContext == null)
            throw new InvalidOperationException("Game-time waits work only while the game runs.");
        if (!sContext.OnGameThread)
            throw new InvalidOperationException("Wait and NextFrame must be awaited on the game thread.");
        if (token.IsCancellationRequested)
            return Task.FromCanceled(token);
        var waiter = new Waiter(float.IsFinite(seconds) ? MathF.Max(seconds, 0f) : float.MaxValue, sFrame, token, owner);
        if (token.CanBeCanceled)
        {
            waiter.Registration = token.Register(static state =>
            {
                var cancelled = (Waiter)state!;
                sWaiters.Remove(cancelled);
                cancelled.Done.TrySetCanceled(cancelled.Token);
            }, waiter);
        }
        sWaiters.Add(waiter);
        return waiter.Done.Task;
    }

    /// <summary>Once a frame, after LateUpdate: finishes the game-time waits that are due, then runs queued
    /// continuations. Throws the first failure after all have run.</summary>
    public static void Pump(float deltaTime)
    {
        if (sContext == null)
            return;
        if (SynchronizationContext.Current != sContext)
            SynchronizationContext.SetSynchronizationContext(sContext);
        sFinished.Clear();
        foreach (Waiter waiter in sWaiters)
        {
            // A wait started this frame ends next frame at the earliest, whatever its length.
            if (waiter.Frame == sFrame)
                continue;
            waiter.Remaining -= deltaTime;
            if (waiter.Remaining <= 0f)
                sFinished.Add(waiter);
        }
        foreach (Waiter waiter in sFinished)
        {
            sWaiters.Remove(waiter);
            waiter.Registration.Dispose();
            // Continuations captured the context, so they are posted to it and run just below.
            waiter.Done.TrySetResult();
        }
        Exception? failure = null;
        try
        {
            EachFrame?.Invoke();
        }
        catch (Exception exception)
        {
            failure = exception;
        }
        failure = sContext.Run() ?? failure;
        sFrame++;
        if (failure != null)
            ExceptionDispatchInfo.Capture(failure).Throw();
    }
}
