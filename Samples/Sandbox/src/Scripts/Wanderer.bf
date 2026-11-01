using System;
using Tallow;

namespace Sandbox;

/// Example component: walks its Navigation Agent to a random reachable spot, waits a moment, and picks another.
[Component]
class Wanderer : Component
{
	/// How far from where it started it wanders.
	public float range = 9;
	public float speed = 2.5f;
	/// Seconds it waits at each spot.
	public float pause = 0.5f;
	/// Sends it this way first (0: a random spot).
	public Vector3 firstGoal;

	NavigationAgent mAgent;
	Vector3 mHome;
	float mWait;
	Random mRandom ~ delete _;
	bool mFirst = true;

	public override void Start()
	{
		mAgent = GetComponent<NavigationAgent>();
		mHome = Transform.Position;
		mRandom = new Random((int32)GameObject.Id);
	}

	public override void Update()
	{
		let data = mAgent?.surface?.Data;
		if (mAgent == null)
			return;
		if (mAgent.IsCrossingLink || (!mAgent.HasArrived && !mAgent.PathFailed && mAgent.Path.Count > 0))
			return;
		mWait -= Time.DeltaTime;
		if (mWait > 0 && !mFirst)
			return;
		mWait = pause;
		if (mFirst && firstGoal != .Zero)
		{
			mFirst = false;
			mAgent.SetDestination(firstGoal, speed, 0.2f);
			return;
		}
		mFirst = false;
		if (data != null && data.RandomPoint(mHome, range, mRandom, let goal))
			mAgent.SetDestination(goal, speed, 0.2f);
		else if (data == null)
			// The surface finds itself on the first request.
			mAgent.SetDestination(mHome, speed, 0.2f);
	}
}
