using System;
using Tallow;

namespace UIDocumentTests;

class Program
{
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		return pass;
	}

	static void Wipe(UIElement element)
	{
		element.text.Clear();
		for (let child in element.children)
			Wipe(child);
	}

	public static int Main(String[] args)
	{
		bool ok = true;
		let data = scope UIDocumentData();
		data.Parse("""
			<panel id="page">
				<panel class="row">
					<button id="slot{i}" class="slot" data="{i}" repeat="4">Slot {n}</button>
				</panel>
				<panel id="group{i}" repeat="2">
					<text id="label{i}">Group {n}</text>
					<text id="item{i}_inner" repeat="0">never</text>
				</panel>
				<slider id="volume" min="0" max="10" step="1" />
				<toggle id="mute" />
				<canvas id="corner" ondraw="OnDraw" />
			</panel>
			""");
		// Parsing a document clears its styles, so they go in afterwards.
		data.styleText.Set("""
			/* A comment before the first rule must not swallow it. */
			#page { position: absolute; left: 0; top: 0; width: 100%; height: 100% }
			.row { flex-direction: row; gap: 10 } /* nor one after a rule */
			.slot { width: 50; height: 20 }
			#corner { position: absolute; right: 30; bottom: 40; width: 100; height: 60 }
			""");
		data.ParseStyles();
		let root = data.root;
		ok &= Check(root != null && root.Find("slot0") != null && root.Find("slot3") != null && root.Find("slot4") == null, "repeat makes the asked number of copies");
		ok &= Check(root.Find("slot{i}") == null, "the element that was repeated is gone");
		let third = root.Find("slot2");
		ok &= Check(third != null && third.text == "Slot 3" && third.attributes.Get("data") == "2", "{n} counts from one and {i} from zero, in text and attributes");
		ok &= Check(third != null && !third.attributes.Has("repeat"), "copies do not repeat again");
		ok &= Check(root.Find("label1") != null && root.Find("label1").text == "Group 2", "children of a repeated element are numbered with it");
		ok &= Check(root.Find("item0_inner") == null, "repeat of nothing leaves nothing");
		let first = root.Find("slot0"), second = root.Find("slot1");
		// Measuring text needs a window's fonts, which a test has not got: lay the elements out without their words.
		Wipe(root);
		data.Layout(800, 600);
		ok &= Check(first != null && second != null && first.width == 50 && Math.Abs(second.x - first.x - 60) < 0.01f, "copies are laid out like any other elements");
		let corner = root.Find("corner");
		ok &= Check(corner != null && Math.Abs(corner.x - 670) < 0.01f && Math.Abs(corner.y - 500) < 0.01f, "a rule after a comment still applies (and pins to the far corner)");
		let page = root.Find("page");
		ok &= Check(page != null && page.width == 800 && page.height == 600, "the first rule survives a comment in front of it");
		// Classes from code.
		first.SetClass("chosen", true);
		ok &= Check(first.HasClass("chosen") && first.HasClass("slot"), "SetClass adds a class and keeps the others");
		first.SetClass("chosen", true);
		ok &= Check(first.attributes.Get("class") == "slot chosen", "adding a class twice adds it once");
		first.SetClass("slot", false);
		ok &= Check(!first.HasClass("slot") && first.HasClass("chosen"), "SetClass takes a class away");
		// Copies are their own elements.
		let copy = first.Clone();
		copy.SetText("changed");
		ok &= Check(first.text.IsEmpty && copy.attributes.Get("data") == "0" && copy.parent == null, "Clone copies an element without tying the two together");
		delete copy;
		// Controls hold a value.
		let volume = root.Find("volume");
		volume.value = 7;
		ok &= Check(volume.tag == "slider" && volume.width == 200 && root.Find("mute").width == 52, "sliders and toggles have a size of their own");
		Console.WriteLine(ok ? "ALL PASSED" : "FAILURES");
		return ok ? 0 : 1;
	}
}
