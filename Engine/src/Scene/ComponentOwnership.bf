using System;
using System.Collections;

namespace Tallow;

/// Optional ownership and scene subscriptions tied to a component lifetime.
extension Component
{
	// Allocated only when used; ordinary Update and component access pay no lookup cost.
	List<Object> mOwnedResources;
	List<delegate void()> mOwnedCleanup;
	bool mOwnershipClosed;

	/// Transfers an exclusively owned heap object to this component. It is deleted after OnDestroy/OnUnregister,
	/// when play stops, or when hot reload retires this instance. Do not delete it yourself or share ownership
	/// with another component. Assets.GetMesh/GetTexture and other shared cache entries are NOT transferable.
	/// Repeated adoption by the same owner is harmless. No ownership is inferred for other fields or object graphs.
	public T Own<T>(T resource) where T : class, delete
	{
		Runtime.Assert(!mOwnershipClosed, "Cannot adopt resources after component cleanup has started.");
		if (resource == null)
			return resource;
		if (mOwnedResources == null)
			mOwnedResources = new .();
		if (!mOwnedResources.Contains(resource))
			mOwnedResources.Add(resource);
		return resource;
	}

	/// Takes ownership of a heap delegate to run once on owner cleanup, before owned resources are deleted.
	/// Use for disconnecting a subscription or cancelling owner-bound work. Callbacks run in reverse registration
	/// order, on the scene thread. They must not destroy this owner or add further cleanup/resources to it.
	/// This does not cancel arbitrary worker threads; cancellation must join them before their data is released.
	public void OnCleanup(delegate void() cleanup)
	{
		Runtime.Assert(!mOwnershipClosed, "Cannot register cleanup after component cleanup has started.");
		if (cleanup == null)
			return;
		if (mOwnedCleanup == null)
			mOwnedCleanup = new .();
		if (!mOwnedCleanup.Contains(cleanup))
			mOwnedCleanup.Add(cleanup);
	}

	/// Subscribes to this scene's world-state changes until play stops, the component is removed or it is retired
	/// by hot reload. Register again in Awake for each play session. The engine owns callback; do not delete it or
	/// register that same delegate elsewhere. Changes are delivered on the scene thread, including while disabled.
	public void ListenWorldState(delegate void(int32 from, int32 to) callback)
	{
		if (callback == null) return;
		Runtime.Assert(!mOwnershipClosed && GameObject?.Scene != null, "A world-state listener needs a live scene owner.");
		let scene = Scene;
		Runtime.Assert(!scene.WorldStateChanged.Contains(callback), "A world-state delegate may only be adopted once.");
		scene.WorldStateChanged.Add(callback);
		OnCleanup(new () =>
			{
				scene.WorldStateChanged.Remove(callback, true).IgnoreError();
			}
			);
	}

	void ReleaseOwned()
	{
		if (mOwnershipClosed)
			return;
		mOwnershipClosed = true;
		if (mOwnedCleanup != null)
		{
			for (int i = mOwnedCleanup.Count - 1; i >= 0; i--)
			{
				let cleanup = mOwnedCleanup[i];
				cleanup();
				delete cleanup;
			}
			mOwnedCleanup.Clear();
		}
		if (mOwnedResources != null)
		{
			for (int i = mOwnedResources.Count - 1; i >= 0; i--)
				delete mOwnedResources[i];
			mOwnedResources.Clear();
		}
	}
}
