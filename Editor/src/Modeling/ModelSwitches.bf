using System;
using Tallow;

namespace Tallow.Editor;

/// Command-line switches for the modeller: --model-window opens the Model window, --model-tab picks its tab,
/// --model-all-tools lists every tool on the Edit tab and --uv-editor opens the UV Editor.
/// --write-first-person-template <folder> writes the new-project character graph (see FirstPersonTemplate).
extension EditorApp
{
	/// Set to open the menu of every tool (the toolbar's All Tools button, or a right-click in the view).
	bool mModelMenuRequest;
	int mFirstPersonWait;

	void ApplyModelSwitches()
	{
		if (HasArg("--model-window"))
			mShowModel = true;
		// --model-tab blockout|edit|paint|texture|model: the Model window's tab; --model-all-tools: every tool on Edit.
		let tab = scope String();
		if (GetArg("--model-tab", tab))
		{
			for (int k < sModelTabNames.Count)
			{
				if (StringView.Compare(tab, StringView(sModelTabNames[k]), true) == 0)
					mModelTabRequest = k;
			}
		}
		if (HasArg("--model-all-tools"))
		{
			mModelWindowLoaded = true;
			mModelAllTools = true;
		}
		if (HasArg("--uv-editor"))
			mShowUVEditor = true;
	}

	/// --write-first-person-template <folder>: writes the new-project character graph to the folder, normally the
	/// engine's Editor/templates/empty/Scripts, a few frames in.
	void TickFirstPersonTemplate()
	{
		if (!HasArg("--write-first-person-template") || ++mFirstPersonWait != 10)
			return;
		FirstPersonTemplate.Write(GetArg("--write-first-person-template", .. scope String()));
	}
}
