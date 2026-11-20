using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;

namespace Tallow;

/// <summary>
/// Runs a piece of work off the game thread where the platform has threads, and in the game thread's own spare
/// time otherwise, so that the same game code works on every platform it ships to: a desktop build gets a
/// <see cref="Task"/> on the thread pool, a web build (whose .NET runs single-threaded) gets the work done a little
/// each frame, within <see cref="BudgetMilliseconds"/>, and the game sees the same finished <see cref="Task"/>.
///
/// The work must only touch its own data (no engine calls, no game objects): the finished result is applied on the
/// game thread, as <see cref="Script.NextFrame"/> continuations are.
///
///   Task&lt;ChunkMesh&gt; task = Background.Run(() => BuildMesh(key, token), token);
///   ... each frame: if (task.IsCompletedSuccessfully) Use(task.Result);
///
/// On a platform with threads a faulted work faults the task; on the fallback the failure is kept the same way, and
/// cancellation ends the task as cancelled before it runs (work that has begun must watch its own token).
/// </summary>
public static class Background
{
    /// <summary>Milliseconds of game-thread time a frame may spend on fallback work (web builds only). Work that
    /// has begun always finishes; the budget only stops another piece being started in the same frame.</summary>
    public static float BudgetMilliseconds = 2f;

    private sealed class Entry
    {
        public Action Run = null!;
        public CancellationTokenRegistration Registration;
    }

    private static readonly Queue<Entry> sQueue = new();
    private static readonly object sLock = new();
    private static int sPending;

    /// <summary>Whether work runs on threads (<c>Task.Run</c>) rather than in the game thread's spare time.</summary>
    public static bool UsesThreads => RuntimeFeature.IsMultithreadingSupported;

    /// <summary>Pieces of work waiting for the game thread's spare time (fallback only).</summary>
    public static int Pending => Volatile.Read(ref sPending);

    /// <summary>Runs work and finishes a task with its result. On a platform with threads the work runs there;
    /// otherwise it is queued for the game thread (see the class summary).</summary>
    public static Task<T> Run<T>(Func<T> work, CancellationToken token = default)
    {
        ArgumentNullException.ThrowIfNull(work);
        if (UsesThreads)
            return Task.Run(work, token);
        var done = new TaskCompletionSource<T>();
        if (token.IsCancellationRequested)
        {
            done.SetCanceled(token);
            return done.Task;
        }
        Enqueue(new Entry
        {
            Run = () =>
            {
                if (token.IsCancellationRequested)
                {
                    done.TrySetCanceled(token);
                    return;
                }
                try
                {
                    done.TrySetResult(work());
                }
                catch (Exception exception)
                {
                    done.TrySetException(exception);
                }
            },
        }, token, () => done.TrySetCanceled(token));
        return done.Task;
    }

    /// <summary>Runs work and finishes a task when it is done. See <see cref="Run{T}"/>.</summary>
    public static Task Run(Action work, CancellationToken token = default)
    {
        ArgumentNullException.ThrowIfNull(work);
        if (UsesThreads)
            return Task.Run(work, token);
        var done = new TaskCompletionSource();
        if (token.IsCancellationRequested)
        {
            done.SetCanceled(token);
            return done.Task;
        }
        Enqueue(new Entry
        {
            Run = () =>
            {
                if (token.IsCancellationRequested)
                {
                    done.TrySetCanceled(token);
                    return;
                }
                try
                {
                    work();
                    done.TrySetResult();
                }
                catch (Exception exception)
                {
                    done.TrySetException(exception);
                }
            },
        }, token, () => done.TrySetCanceled(token));
        return done.Task;
    }

    private static void Enqueue(Entry entry, CancellationToken token, Action cancelled)
    {
        lock (sLock)
        {
            sQueue.Enqueue(entry);
            Interlocked.Increment(ref sPending);
        }
        if (token.CanBeCanceled)
            entry.Registration = token.Register(() => cancelled());
    }

    /// <summary>Runs queued fallback work until the frame's budget is used (one piece always runs). Called once a
    /// frame on the game thread, after LateUpdate; the first failure is returned for the frame to report.</summary>
    internal static Exception? Pump()
    {
        if (Volatile.Read(ref sPending) == 0)
            return null;
        long start = Stopwatch.GetTimestamp();
        Exception? failure = null;
        while (true)
        {
            Entry? entry;
            lock (sLock)
            {
                if (sQueue.Count == 0)
                {
                    Volatile.Write(ref sPending, 0);
                    return failure;
                }
                entry = sQueue.Dequeue();
            }
            Interlocked.Decrement(ref sPending);
            entry.Registration.Dispose();
            try
            {
                entry.Run();
            }
            catch (Exception exception)
            {
                failure ??= exception;
            }
            if (Stopwatch.GetElapsedTime(start).TotalMilliseconds >= BudgetMilliseconds)
                return failure;
        }
    }
}
