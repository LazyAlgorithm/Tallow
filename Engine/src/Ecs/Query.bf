using System;
using System.Collections;
using System.Diagnostics;

namespace Tallow;

/// One run of a query's results: entities that share a table, with each term's data as a packed column.
/// Read<T>() and Write<T>() give a term's column (the same memory; the names say what the code means to do).
/// A chunk is only valid inside the loop that produced it.
struct Chunk
{
	void* mIterator;
	QueryBase mQuery;
	int32 mCount;

	public this(void* iterator, QueryBase query)
	{
		mIterator = iterator;
		mQuery = query;
		mCount = Flecs.IterCount(iterator);
	}

	public int Count => mCount;

	public Span<Entity> Entities => .((Entity*)Flecs.IterEntities(mIterator), mCount);

	/// The column of the query's term number term (0 is the first type argument). Empty for an Optional term
	/// this chunk lacks.
	public Span<T> Field<T>(int term) where T : struct
	{
		let data = (T*)Flecs.IterField(mIterator, (int32)term, strideof(T));
		if (data == null)
			return .();
		Debug.Assert(Flecs.IterFieldIsSelf(mIterator, (int32)term), "Query term matched a shared value; Tallow queries only match an entity's own data");
		return .(data, mCount);
	}

	public Span<T> Read<T>() where T : struct => Field<T>(mQuery.TermOf(ComponentId<T>.Index));
	public Span<T> Write<T>() where T : struct => Field<T>(mQuery.TermOf(ComponentId<T>.Index));
}

/// A cached Flecs query over up to four data component types (Query<A>, Query<A, B>...). Make one once and keep it:
/// Flecs keeps the list of matching tables up to date as entities change. Iterate it on the main thread with
/// `for (var chunk in query)`, or over every thread with ParallelFor.
abstract class QueryBase
{
	protected World mWorld;
	protected void* mQuery;
	/// The ComponentTypes index of each term's type, for Chunk.Read/Write.
	protected int32[4] mTypes;
	protected int32 mTermCount;

	protected void Create(World world, Span<uint64> ids, Span<Flecs.TermAccess> access, Span<int32> types)
	{
		mWorld = world;
		mTermCount = (int32)ids.Length;
		for (int i < types.Length)
			mTypes[i] = types[i];
		mQuery = Flecs.QueryNew(world.Native, ids.Ptr, access.Ptr, mTermCount);
		Runtime.Assert(mQuery != null, "Flecs refused the query");
	}

	public ~this()
	{
		if (mQuery != null)
			Flecs.QueryFree(mQuery);
	}

	public World World => mWorld;

	/// How many entities match (walks the matching tables).
	public int Count => Flecs.QueryCount(mQuery);

	/// The term whose type has ComponentTypes index type.
	public int TermOf(int32 type)
	{
		for (int i < mTermCount)
		{
			if (mTypes[i] == type)
				return i;
		}
		Runtime.FatalError("Chunk.Read/Write asked for a type that is not in the query");
	}

	public Enumerator GetEnumerator() => .(this);

	/// Runs body on every chunk, over Tallow's worker threads (Jobs) and this one. Each thread gets its own share of
	/// every table, so bodies must only touch the rows they are given. The world is read-only for structure while
	/// this runs: no Create, Add, Remove or Delete in body.
	public void ParallelFor(delegate void(Chunk chunk) body)
	{
		let threads = Jobs.ThreadCount;
		if (threads <= 1)
		{
			for (var chunk in this)
				body(chunk);
			return;
		}
		let world = mWorld.Native;
		mWorld.EnsureStages(threads);
		Flecs.ReadonlyBegin(world, true);
		Jobs.For(threads, scope (index) =>
			{
				Flecs.WorkerIterBuffer buffer = ?;
				Flecs.QueryWorkerIter(Flecs.Stage(world, Jobs.ThreadIndex), mQuery, (int32)index, threads, &buffer);
				while (Flecs.IterNext(&buffer.iterator))
					body(Chunk(&buffer.iterator, this));
			});
		Flecs.ReadonlyEnd(world);
	}

	public struct Enumerator : IEnumerator<Chunk>, IDisposable
	{
		QueryBase mQuery;
		Flecs.IterBuffer mBuffer;
		bool mStarted;
		bool mDone;

		public this(QueryBase query)
		{
			mQuery = query;
			mBuffer = ?;
			mStarted = false;
			mDone = false;
		}

		public Result<Chunk> GetNext() mut
		{
			if (mDone)
				return .Err;
			// Started here rather than in the constructor: the iterator must not move once it is running.
			if (!mStarted)
			{
				mStarted = true;
				Flecs.QueryIter(mQuery.mWorld.Native, mQuery.mQuery, &mBuffer);
			}
			if (!Flecs.IterNext(&mBuffer))
			{
				mDone = true;
				return .Err;
			}
			return Chunk(&mBuffer, mQuery);
		}

		/// Ends an iteration left early (break or return in the loop).
		public void Dispose() mut
		{
			if (mStarted && !mDone)
				Flecs.IterFini(&mBuffer);
			mDone = true;
		}
	}
}

class Query<T1> : QueryBase where T1 : struct
{
	public this(World world, Flecs.TermAccess access1 = .ReadWrite)
	{
		uint64[1] ids = .(world.Id<T1>());
		Flecs.TermAccess[1] access = .(access1);
		int32[1] types = .(ComponentId<T1>.Index);
		Create(world, ids, access, types);
	}
}

class Query<T1, T2> : QueryBase where T1 : struct where T2 : struct
{
	public this(World world, Flecs.TermAccess access1 = .ReadWrite, Flecs.TermAccess access2 = .ReadWrite)
	{
		uint64[2] ids = .(world.Id<T1>(), world.Id<T2>());
		Flecs.TermAccess[2] access = .(access1, access2);
		int32[2] types = .(ComponentId<T1>.Index, ComponentId<T2>.Index);
		Create(world, ids, access, types);
	}
}

class Query<T1, T2, T3> : QueryBase where T1 : struct where T2 : struct where T3 : struct
{
	public this(World world, Flecs.TermAccess access1 = .ReadWrite, Flecs.TermAccess access2 = .ReadWrite, Flecs.TermAccess access3 = .ReadWrite)
	{
		uint64[3] ids = .(world.Id<T1>(), world.Id<T2>(), world.Id<T3>());
		Flecs.TermAccess[3] access = .(access1, access2, access3);
		int32[3] types = .(ComponentId<T1>.Index, ComponentId<T2>.Index, ComponentId<T3>.Index);
		Create(world, ids, access, types);
	}
}

class Query<T1, T2, T3, T4> : QueryBase where T1 : struct where T2 : struct where T3 : struct where T4 : struct
{
	public this(World world, Flecs.TermAccess access1 = .ReadWrite, Flecs.TermAccess access2 = .ReadWrite, Flecs.TermAccess access3 = .ReadWrite, Flecs.TermAccess access4 = .ReadWrite)
	{
		uint64[4] ids = .(world.Id<T1>(), world.Id<T2>(), world.Id<T3>(), world.Id<T4>());
		Flecs.TermAccess[4] access = .(access1, access2, access3, access4);
		int32[4] types = .(ComponentId<T1>.Index, ComponentId<T2>.Index, ComponentId<T3>.Index, ComponentId<T4>.Index);
		Create(world, ids, access, types);
	}
}

/// A query whose types are known only when it runs (ComponentTypes indices): what the engine uses to list the
/// objects with a given component handle.
class IndexQuery : QueryBase
{
	public this(World world, Span<int32> types, Span<Flecs.TermAccess> access)
	{
		Runtime.Assert(types.Length <= 4 && types.Length == access.Length);
		uint64[4] ids = default;
		for (int i < types.Length)
			ids[i] = world.IdOf(types[i]);
		Create(world, .(&ids, types.Length), access, types);
	}
}
