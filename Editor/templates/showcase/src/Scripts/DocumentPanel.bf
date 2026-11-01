using System;
using Tallow;

namespace {NAMESPACE};

[Component]
class DocumentPanel : Component
{
	public float value = 0.6f;
	public void OnMore()
	{
		value = Math.Min(value + 0.1f, 1);
	}

	public void OnLess()
	{
		value = Math.Max(value - 0.1f, 0);
	}

	public void OnClose()
	{
		GetComponent<UIDocument>().Enabled = false;
	}
}
