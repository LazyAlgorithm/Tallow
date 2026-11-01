using System;
using System.Collections;

namespace Tallow;

/// Something whose [Saved] fields can be written and read. The engine adds this, and the code behind it, to every
/// class and struct that has a field marked [Saved]; nothing has to be written by hand.
interface ISaveable
{
	void SaveFields(SaveIO io) mut;
}

/// Turns object references into numbers in a save and back, and finds components by their object. SaveSystem
/// provides one while it saves or loads a scene; data saved on its own (a data asset) has none, and references in it
/// are saved as empty.
interface ISaveReferences
{
	int64 KeyOf(GameObject gameObject);
	GameObject Find(int64 key);
}

/// Reads or writes values: the same generated code does both, passing each [Saved] field by reference. Writing
/// builds a SaveNode tree; reading walks one and puts the values back. Code generated for [Saved] fields calls this,
/// and OnSaving / OnLoaded code can too, to keep values of its own:
///
///   public override void SaveFields(SaveIO io)
///   {
///       base.SaveFields(io);
///       if (io.Key("visits")) io.Value(ref mVisits);
///   }
class SaveIO
{
	struct Frame
	{
		public SaveNode node;
		public int cursor;
	}

	/// BeginList's answer when the saved value is missing or is not a list: leave the field as it is.
	public const int Absent = -2;

	bool mReading;
	SaveNode mRoot;
	bool mOwnsRoot;
	List<Frame> mStack = new .() ~ delete _;
	/// Reading: the value the next call reads. Writing: unused.
	SaveNode mCurrent;
	/// Writing: the name the next value is stored under, in an object.
	String mPendingKey = new .() ~ delete _;
	/// How references to objects and components are turned into keys and back.
	public ISaveReferences references;

	/// Whether this is loading (values are set from the save).
	public bool Reading => mReading;
	/// Whether this is saving (values are written into the save).
	public bool Writing => !mReading;
	/// Writing: what has been written so far (the object passed to the constructor's caller, or the one made here).
	public SaveNode Root => mRoot;

	/// Writes into a new object node; take it with TakeRoot when done.
	public this()
	{
		mRoot = new SaveNode(.Object);
		mOwnsRoot = true;
		mStack.Add(.() { node = mRoot });
	}

	/// Reads from a node, which stays the caller's.
	public this(SaveNode reading)
	{
		mReading = true;
		mRoot = reading;
		mStack.Add(.() { node = reading });
	}

	public ~this()
	{
		if (mOwnsRoot)
			delete mRoot;
	}

	/// Writing: hands the tree over to the caller.
	public SaveNode TakeRoot()
	{
		mOwnsRoot = false;
		return mRoot;
	}

	SaveNode Container => mStack.Back.node;

	/// Inside an object: the next value is the one named key. Reading, false when the save has no such value, and
	/// the field keeps what it had.
	public bool Key(StringView key)
	{
		if (!mReading)
		{
			mPendingKey.Set(key);
			return true;
		}
		let container = Container;
		mCurrent = container != null && container.kind == .Object ? container[key] : null;
		return mCurrent != null;
	}

	/// Inside a list: moves to the next item. Reading, false when the save's list has no more.
	public bool Item()
	{
		if (!mReading)
		{
			mPendingKey.Clear();
			return true;
		}
		var frame = ref mStack.Back;
		if (frame.node == null || frame.node.kind != .List || frame.cursor >= frame.node.items.Count)
		{
			mCurrent = null;
			return false;
		}
		mCurrent = frame.node.items[frame.cursor++];
		return true;
	}

	void Put(SaveNode node)
	{
		let container = Container;
		if (container.kind == .Object)
			container.Set(mPendingKey, node);
		else
			container.items.Add(node);
		mPendingKey.Clear();
	}

	// ---- containers ----

	/// Starts a list of count values (-1 for a null collection). Reading, returns how many the save has, -1 if it
	/// saved null, or Absent if it has no list here. Call Item before each value and EndList after.
	public int BeginList(int count)
	{
		if (!mReading)
		{
			let node = new SaveNode(count < 0 ? .Null : .List);
			Put(node);
			mStack.Add(.() { node = node });
			return count;
		}
		let node = mCurrent;
		mStack.Add(.() { node = node });
		if (node == null)
			return Absent;
		if (node.kind == .Null)
			return -1;
		if (node.kind != .List)
			return Absent;
		return node.items.Count;
	}

	/// Ends a list begun with BeginList.
	public void EndList()
	{
		mStack.PopBack();
		mCurrent = null;
	}

	/// Starts an object (present: false for a null one). Reading, returns whether the save has an object here.
	public bool BeginObject(bool present = true)
	{
		if (!mReading)
		{
			let node = new SaveNode(present ? .Object : .Null);
			Put(node);
			mStack.Add(.() { node = node });
			return present;
		}
		let node = mCurrent;
		mStack.Add(.() { node = node });
		return node != null && node.kind == .Object;
	}

	/// Reading: whether the value here was saved as null.
	public bool IsNull => mReading && mCurrent != null && mCurrent.kind == .Null;

	/// Ends an object begun with BeginObject.
	public void EndObject()
	{
		mStack.PopBack();
		mCurrent = null;
	}

	// ---- values ----

	void PutInt(int64 value) => Put(SaveNode.MakeInt(value));
	void PutFloat(double value) => Put(SaveNode.MakeFloat(value));

	bool GetNumber(out double value)
	{
		value = 0;
		if (mCurrent == null || (mCurrent.kind != .Int && mCurrent.kind != .Float && mCurrent.kind != .Bool))
			return false;
		value = mCurrent.AsNumber;
		return true;
	}

	bool GetInteger(out int64 value)
	{
		value = 0;
		if (mCurrent == null || (mCurrent.kind != .Int && mCurrent.kind != .Float && mCurrent.kind != .Bool))
			return false;
		value = mCurrent.AsInteger;
		return true;
	}

	/// Writes the value when saving, or sets it from the save when loading. Every kind of value has one of these.
	public void Value(ref bool value)
	{
		if (!mReading)
			Put(SaveNode.MakeBool(value));
		else if (GetInteger(let v))
			value = v != 0;
	}

	public void Value(ref int8 value)
	{
		if (!mReading)
			PutInt(value);
		else if (GetInteger(let v))
			value = (int8)v;
	}

	public void Value(ref int16 value)
	{
		if (!mReading)
			PutInt(value);
		else if (GetInteger(let v))
			value = (int16)v;
	}

	public void Value(ref int32 value)
	{
		if (!mReading)
			PutInt(value);
		else if (GetInteger(let v))
			value = (int32)v;
	}

	public void Value(ref int64 value)
	{
		if (!mReading)
			PutInt(value);
		else if (GetInteger(let v))
			value = v;
	}

	public void Value(ref int value)
	{
		if (!mReading)
			PutInt(value);
		else if (GetInteger(let v))
			value = (int)v;
	}

	public void Value(ref uint8 value)
	{
		if (!mReading)
			PutInt(value);
		else if (GetInteger(let v))
			value = (uint8)v;
	}

	public void Value(ref uint16 value)
	{
		if (!mReading)
			PutInt(value);
		else if (GetInteger(let v))
			value = (uint16)v;
	}

	public void Value(ref uint32 value)
	{
		if (!mReading)
			PutInt(value);
		else if (GetInteger(let v))
			value = (uint32)v;
	}

	public void Value(ref uint64 value)
	{
		if (!mReading)
			PutInt((int64)value);
		else if (GetInteger(let v))
			value = (uint64)v;
	}

	public void Value(ref uint value)
	{
		if (!mReading)
			PutInt((int64)value);
		else if (GetInteger(let v))
			value = (uint)v;
	}

	public void Value(ref char8 value)
	{
		if (!mReading)
			PutInt((uint8)value);
		else if (GetInteger(let v))
			value = (char8)(uint8)v;
	}

	public void Value(ref char16 value)
	{
		if (!mReading)
			PutInt((uint16)value);
		else if (GetInteger(let v))
			value = (char16)(uint16)v;
	}

	public void Value(ref char32 value)
	{
		if (!mReading)
			PutInt((uint32)value);
		else if (GetInteger(let v))
			value = (char32)(uint32)v;
	}

	public void Value(ref float value)
	{
		if (!mReading)
			PutFloat(value);
		else if (GetNumber(let v))
			value = (float)v;
	}

	public void Value(ref double value)
	{
		if (!mReading)
			PutFloat(value);
		else if (GetNumber(let v))
			value = v;
	}

	/// A null String is saved as null; reading into a null field makes a new String, which the field then owns.
	public void Value(ref String value)
	{
		if (!mReading)
		{
			Put(value == null ? new SaveNode(.Null) : SaveNode.MakeString(value));
			return;
		}
		if (mCurrent == null)
			return;
		if (mCurrent.kind == .Null)
		{
			DeleteAndNullify!(value);
			return;
		}
		if (mCurrent.kind != .String)
			return;
		if (value == null)
			value = new String();
		value.Set(mCurrent.text);
	}

	/// A fixed number of floats, saved as a list.
	void Floats(float* values, int count)
	{
		if (BeginList(count) >= 0 || !mReading)
		{
			for (int i < count)
			{
				if (!Item())
					break;
				Value(ref values[i]);
			}
		}
		EndList();
	}

	public void Value(ref Vector2 value) => Floats(&value.x, 2);
	public void Value(ref Vector3 value) => Floats(&value.x, 3);
	public void Value(ref Vector4 value) => Floats(&value.x, 4);
	public void Value(ref Quaternion value) => Floats(&value.x, 4);
	public void Value(ref Color value) => Floats(&value.r, 4);
	public void Value(ref Matrix4 value) => Floats(&value.m[0], 16);

	public void Value(ref Int3 value)
	{
		if (BeginList(3) >= 0 || !mReading)
		{
			if (Item())
				Value(ref value.x);
			if (Item())
				Value(ref value.y);
			if (Item())
				Value(ref value.z);
		}
		EndList();
	}

	/// An object in the scene, saved as its place in the save (SaveSystem's references). Reading, the object that
	/// place holds now: the same scene object, or the one recreated in place of a spawned one.
	public void Value(ref GameObject value)
	{
		if (!mReading)
		{
			let key = value != null && references != null ? references.KeyOf(value) : 0;
			Put(key != 0 ? SaveNode.MakeInt(key) : new SaveNode(.Null));
			return;
		}
		if (mCurrent == null)
			return;
		value = mCurrent.kind == .Int && references != null ? references.Find(mCurrent.integer) : null;
	}

	/// A transform's local position, rotation and scale.
	public void Value(ref Transform value)
	{
		var gameObject = value?.GameObject;
		Value(ref gameObject);
		if (mReading && mCurrent != null)
			value = gameObject?.Transform;
	}

	/// A component in the scene: its object, its type and which of that type on the object it is.
	public void Component<T>(ref T value) where T : Component
	{
		if (!mReading)
		{
			if (value == null || references == null)
			{
				Put(new SaveNode(.Null));
				return;
			}
			BeginList(3);
			Item();
			var gameObject = value.GameObject;
			Value(ref gameObject);
			Item();
			var typeName = scope String();
			value.GetType().GetFullName(typeName);
			Value(ref typeName);
			Item();
			int32 index = 0;
			for (let other in value.GameObject.Components)
			{
				if (other == value)
					break;
				if (other.GetType() == value.GetType())
					index++;
			}
			Value(ref index);
			EndList();
			return;
		}
		if (mCurrent == null)
			return;
		if (mCurrent.kind != .List)
		{
			value = null;
			return;
		}
		GameObject gameObject = null;
		String typeName = scope String();
		int32 index = 0;
		BeginList(3);
		if (Item())
			Value(ref gameObject);
		if (Item())
			Value(ref typeName);
		if (Item())
			Value(ref index);
		EndList();
		value = null;
		if (gameObject == null)
			return;
		int32 seen = 0;
		let name = scope String();
		for (let other in gameObject.Components)
		{
			name.Clear();
			other.GetType().GetFullName(name);
			if (name != typeName)
				continue;
			if (seen++ == index)
			{
				value = other as T;
				break;
			}
		}
	}

	/// An enum, saved as its number.
	public void Enum<T>(ref T value) where T : struct
	{
		int64 number = 0;
		if (!mReading)
		{
			switch (sizeof(T))
			{
			case 1: number = *(int8*)&value;
			case 2: number = *(int16*)&value;
			case 4: number = *(int32*)&value;
			default: number = *(int64*)&value;
			}
			PutInt(number);
			return;
		}
		if (!GetInteger(out number))
			return;
		switch (sizeof(T))
		{
		case 1: *(int8*)&value = (int8)number;
		case 2: *(int16*)&value = (int16)number;
		case 4: *(int32*)&value = (int32)number;
		default: *(int64*)&value = number;
		}
	}
}
