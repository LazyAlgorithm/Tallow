using System.Numerics;
using Tallow;

namespace Sandbox;

/// <summary>Walks its Navigation Agent to a random reachable spot, waits a moment, and picks another.</summary>
public class Wanderer : Script
{
    /// <summary>How far from where it started it wanders.</summary>
    public float Range = 9;
    public float Speed = 2.5f;
    /// <summary>Seconds it waits at each spot.</summary>
    public float Pause = 0.5f;
    /// <summary>Sends it this way first (zero: a random spot).</summary>
    public Vector3 FirstGoal;

    private Vector3 _home;
    private float _wait;
    private System.Random _random = new();
    private bool _first = true;

    public override void Start()
    {
        _home = Transform.Position;
        // The same seed on every machine: the same spots.
        _random = new System.Random((int)GameObject.Id);
    }

    public override void Update(TickInput input, float deltaTime)
    {
        NavigationAgent agent = GetComponent<NavigationAgent>();
        if (!agent.IsValid)
            return;
        if (agent.IsCrossingLink || (!agent.HasArrived && !agent.PathFailed && agent.PathCornerCount > 0))
            return;
        _wait -= deltaTime;
        if (_wait > 0 && !_first)
            return;
        _wait = Pause;
        if (_first && FirstGoal != Vector3.Zero)
        {
            _first = false;
            agent.SetDestination(FirstGoal, Speed);
            return;
        }
        _first = false;
        NavigationSurface surface = NavigationSurface.Find(Scene);
        if (!surface.IsValid)
            agent.SetDestination(_home, Speed); // The surface finds itself on the first request.
        else if (surface.RandomPoint(_home, Range, _random, out Vector3 goal))
            agent.SetDestination(goal, Speed);
    }
}
