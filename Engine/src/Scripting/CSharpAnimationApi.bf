using System;

namespace Tallow;

/// Animator for C# scripts (Tallow.API's Animator handle). Each call names the object by session and entity; a
/// missing object or one without an Animator does nothing and reads as zero.
[CSharpExpose]
static class CSharpAnimation
{
	static bool Find(uint64 session, uint64 entity, out Animator animator)
	{
		animator = default;
		let obj = CSharpRuntime.PhysicsObject(session, entity);
		if (obj == null || !obj.HasComponent<Animator>())
			return false;
		animator = obj.GetComponent<Animator>();
		return true;
	}

	static int32 Copy(StringView text, Span<uint8> buffer)
	{
		let count = Math.Min(text.Length, buffer.Length);
		for (int i < count)
			buffer[i] = (uint8)text[i];
		return (int32)text.Length;
	}

	[CSharpExpose]
	public static bool HasAnimator(uint64 session, uint64 entity) => Find(session, entity, ?);

	[CSharpExpose]
	public static void Play(uint64 session, uint64 entity, StringView clip, float fadeSeconds)
	{
		if (Find(session, entity, let animator))
			animator.Play(clip, fadeSeconds);
	}

	[CSharpExpose]
	public static void CrossFade(uint64 session, uint64 entity, StringView state, float fadeSeconds)
	{
		if (Find(session, entity, let animator))
			animator.CrossFade(state, fadeSeconds);
	}

	[CSharpExpose]
	public static bool HasClip(uint64 session, uint64 entity, StringView clip) => Find(session, entity, let animator) && animator.HasClip(clip);

	/// The clip playing (UTF-8 into buffer; returns its full length, -1 without an Animator).
	[CSharpExpose]
	public static int32 CopyCurrentClip(uint64 session, uint64 entity, Span<uint8> buffer) =>
		Find(session, entity, let animator) ? Copy(animator.CurrentClip, buffer) : -1;

	/// The controller state playing (as CopyCurrentClip).
	[CSharpExpose]
	public static int32 CopyCurrentState(uint64 session, uint64 entity, Span<uint8> buffer) =>
		Find(session, entity, let animator) ? Copy(animator.CurrentState, buffer) : -1;

	[CSharpExpose]
	public static bool IsFinished(uint64 session, uint64 entity) => Find(session, entity, let animator) && animator.IsFinished;

	[CSharpExpose]
	public static bool IsInTransition(uint64 session, uint64 entity) => Find(session, entity, let animator) && animator.IsInTransition;

	[CSharpExpose]
	public static float GetSpeed(uint64 session, uint64 entity) => Find(session, entity, let animator) ? animator.speed : 0;

	[CSharpExpose]
	public static void SetSpeed(uint64 session, uint64 entity, float speed)
	{
		if (Find(session, entity, var animator))
			animator.speed = speed;
	}

	[CSharpExpose]
	public static float GetNormalizedTime(uint64 session, uint64 entity) => Find(session, entity, let animator) ? animator.NormalizedTime : 0;

	[CSharpExpose]
	public static float GetStateTime(uint64 session, uint64 entity) => Find(session, entity, let animator) ? animator.StateTime : 0;

	[CSharpExpose]
	public static void SetFloat(uint64 session, uint64 entity, StringView name, float value)
	{
		if (Find(session, entity, let animator))
			animator.SetFloat(name, value);
	}

	[CSharpExpose]
	public static void SetInteger(uint64 session, uint64 entity, StringView name, int32 value)
	{
		if (Find(session, entity, let animator))
			animator.SetInteger(name, value);
	}

	[CSharpExpose]
	public static void SetBool(uint64 session, uint64 entity, StringView name, bool value)
	{
		if (Find(session, entity, let animator))
			animator.SetBool(name, value);
	}

	[CSharpExpose]
	public static void SetTrigger(uint64 session, uint64 entity, StringView name)
	{
		if (Find(session, entity, let animator))
			animator.SetTrigger(name);
	}

	[CSharpExpose]
	public static void ResetTrigger(uint64 session, uint64 entity, StringView name)
	{
		if (Find(session, entity, let animator))
			animator.ResetTrigger(name);
	}

	[CSharpExpose]
	public static float GetFloat(uint64 session, uint64 entity, StringView name) => Find(session, entity, let animator) ? animator.GetFloat(name) : 0;

	[CSharpExpose]
	public static int32 GetInteger(uint64 session, uint64 entity, StringView name) => Find(session, entity, let animator) ? animator.GetInteger(name) : 0;

	[CSharpExpose]
	public static bool GetBool(uint64 session, uint64 entity, StringView name) => Find(session, entity, let animator) && animator.GetBool(name);

	[CSharpExpose]
	public static int32 GetLayerCount(uint64 session, uint64 entity) => Find(session, entity, let animator) ? animator.LayerCount : 0;

	[CSharpExpose]
	public static void SetLayerWeight(uint64 session, uint64 entity, int32 layer, float weight)
	{
		if (Find(session, entity, let animator))
			animator.SetLayerWeight(layer, weight);
	}

	[CSharpExpose]
	public static float GetLayerWeight(uint64 session, uint64 entity, int32 layer) => Find(session, entity, let animator) ? animator.GetLayerWeight(layer) : 0;
}
