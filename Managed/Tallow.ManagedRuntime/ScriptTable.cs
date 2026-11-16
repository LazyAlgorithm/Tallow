using System.Diagnostics.CodeAnalysis;
using Tallow;

namespace Tallow.ManagedRuntime;

/// <summary>
/// The attached scripts by instance id, for the engine's per-frame calls. An id is a slot (low 22 bits) and that
/// slot's generation (the 9 bits above), so a lookup is an array index and a compare rather than a hash, slots are
/// reused as scripts come and go, and an old id does not find the script that took its slot after it (until the
/// slot has been reused 511 times; the engine forgets an id when it detaches it).
/// </summary>
internal sealed class ScriptTable
{
    private const int SlotBits = 22;
    private const int SlotMask = (1 << SlotBits) - 1;
    private const int MaxGeneration = 511;

    private struct Entry
    {
        public int Id;
        public Script? Script;
    }

    private Entry[] _entries = new Entry[256];
    private int _used; // Slots ever handed out (1 based: slot 0 is never used, so no id is 0).
    private readonly Stack<int> _free = new();

    public int Count { get; private set; }

    /// <summary>The id the next <see cref="Add"/> will use.</summary>
    public int NextId()
    {
        if (_free.TryPeek(out int slot))
            return Compose(slot, _entries[slot].Id);
        if (_used + 1 > SlotMask)
            throw new InvalidOperationException("Too many C# scripts at once (4 million).");
        return Compose(_used + 1, 0);
    }

    private static int Compose(int slot, int previousId)
    {
        int generation = (previousId >> SlotBits) + 1;
        if (generation > MaxGeneration)
            generation = 1;
        return (generation << SlotBits) | slot;
    }

    /// <summary>Adds a script under the id <see cref="NextId"/> gave.</summary>
    public void Add(int id, Script script)
    {
        if (id != NextId())
            throw new InvalidOperationException("C# script ids must be added in the order NextId gives them.");
        int slot = id & SlotMask;
        if (_free.Count > 0)
            _free.Pop();
        else
        {
            _used = slot;
            if (slot >= _entries.Length)
                Array.Resize(ref _entries, Math.Max(_entries.Length * 2, slot + 1));
        }
        _entries[slot] = new Entry { Id = id, Script = script };
        Count++;
    }

    public bool TryGetValue(int id, [NotNullWhen(true)] out Script? script)
    {
        int slot = id & SlotMask;
        Entry[] entries = _entries;
        if ((uint)slot < (uint)entries.Length && entries[slot].Id == id && id > 0)
        {
            script = entries[slot].Script;
            return script is not null;
        }
        script = null;
        return false;
    }

    public bool ContainsKey(int id) => TryGetValue(id, out _);

    /// <summary>Puts another script under an id in use (hot reload: the same script in the new code).</summary>
    public void Replace(int id, Script script)
    {
        if (!TryGetValue(id, out _))
            throw new InvalidOperationException("Only a script id in use can be given another script.");
        _entries[id & SlotMask].Script = script;
    }

    public bool Remove(int id, [NotNullWhen(true)] out Script? script)
    {
        if (!TryGetValue(id, out script))
            return false;
        int slot = id & SlotMask;
        _entries[slot].Script = null; // Keeps Id, so the slot's next id is a new generation.
        _free.Push(slot);
        Count--;
        return true;
    }

    public void Clear()
    {
        Array.Clear(_entries);
        _free.Clear();
        _used = 0;
        Count = 0;
    }

    /// <summary>Every attached script with its id, in slot order.</summary>
    public IEnumerable<(int Id, Script Script)> All()
    {
        for (int slot = 1; slot <= _used; slot++)
        {
            Entry entry = _entries[slot];
            if (entry.Script is not null)
                yield return (entry.Id, entry.Script);
        }
    }
}
