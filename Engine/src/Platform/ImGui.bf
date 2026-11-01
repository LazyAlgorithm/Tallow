using System;

namespace Tallow;

/// Dear ImGui (docking branch) through cimgui. Only the subset the engine and editor use is declared;
/// add more externs here as needed, the names match cimgui.h.
static class ImGui
{
	[CRepr]
	public struct Vec2
	{
		public float x;
		public float y;
		public this(float x, float y)
		{
			this.x = x;
			this.y = y;
		}
	}

	[CRepr]
	public struct Vec4
	{
		public float x;
		public float y;
		public float z;
		public float w;
		public this(float x, float y, float z, float w)
		{
			this.x = x;
			this.y = y;
			this.z = z;
			this.w = w;
		}
	}

	[CRepr]
	public struct TextureRef
	{
		public void* texData;
		public uint64 texId;
	}

	[CRepr]
	public struct Viewport
	{
		public uint32 id;
		public int32 flags;
		public Vec2 pos;
		public Vec2 size;
		public Vec2 framebufferScale;
		public Vec2 workPos;
		public Vec2 workSize;
	}

	[CRepr]
	public static class DragDropFlags
	{
		/// A drag started by code rather than by an item (the Scene view's objects): call BeginDragDropSource with it
		/// every frame the drag lasts.
		public const int32 SourceExtern = 1 << 4;
		/// Hands the payload to a target while the mouse is still held over it (for a preview), as well as on release.
		public const int32 AcceptBeforeDelivery = 1 << 10;
		public const int32 AcceptNoDrawDefaultRect = 1 << 11;
	}

	public struct Payload
	{
		public void* data;
		public int32 dataSize;
	}

	public static class WindowFlags
	{
		public const int32 None = 0;
		public const int32 NoTitleBar = 1 << 0;
		public const int32 NoResize = 1 << 1;
		public const int32 NoMove = 1 << 2;
		public const int32 NoScrollbar = 1 << 3;
		public const int32 NoScrollWithMouse = 1 << 4;
		public const int32 NoCollapse = 1 << 5;
		public const int32 AlwaysAutoResize = 1 << 6;
		public const int32 NoBackground = 1 << 7;
		public const int32 NoSavedSettings = 1 << 8;
		public const int32 MenuBar = 1 << 10;
		public const int32 HorizontalScrollbar = 1 << 11;
		public const int32 NoBringToFrontOnFocus = 1 << 13;
		public const int32 NoNavFocus = 1 << 17;
		public const int32 NoDocking = 1 << 19;
		public const int32 NoDecoration = NoTitleBar | NoResize | NoScrollbar | NoCollapse;
		public const int32 NoInputs = 197120;
	}

	public static class TreeFlags
	{
		public const int32 None = 0;
		public const int32 Selected = 1 << 0;
		public const int32 Framed = 1 << 1;
		public const int32 AllowOverlap = 1 << 2;
		public const int32 NoTreePushOnOpen = 1 << 3;
		public const int32 DefaultOpen = 1 << 5;
		public const int32 OpenOnDoubleClick = 1 << 6;
		public const int32 OpenOnArrow = 1 << 7;
		public const int32 Leaf = 1 << 8;
		public const int32 FramePadding = 1 << 10;
		public const int32 SpanAvailWidth = 1 << 11;
		public const int32 SpanFullWidth = 1 << 12;
	}

	public static class Col
	{
		public const int32 Text = 0;
		public const int32 WindowBg = 2;
		public const int32 ChildBg = 3;
		public const int32 FrameBg = 7;
		public const int32 Button = 22;
		public const int32 ButtonHovered = 23;
		public const int32 ButtonActive = 24;
		public const int32 Header = 25;
		public const int32 HeaderHovered = 26;
		public const int32 HeaderActive = 27;
		public const int32 TextDisabled = 1;
		public const int32 PopupBg = 4;
		public const int32 Border = 5;
		public const int32 CheckMark = 18;
	}

	public static class StyleVar
	{
		public const int32 Alpha = 0;
		public const int32 WindowPadding = 2;
		public const int32 WindowRounding = 3;
		public const int32 WindowBorderSize = 4;
		public const int32 FramePadding = 11;
		public const int32 FrameRounding = 12;
		public const int32 FrameBorderSize = 13;
		public const int32 ItemSpacing = 14;
		public const int32 ItemInnerSpacing = 15;
		public const int32 IndentSpacing = 16;
		public const int32 CellPadding = 17;
	}

	public static class Cond
	{
		public const int32 Always = 1 << 0;
		public const int32 Once = 1 << 1;
		public const int32 FirstUseEver = 1 << 2;
		public const int32 Appearing = 1 << 3;
	}

	public static class Dir
	{
		public const int32 Left = 0;
		public const int32 Right = 1;
		public const int32 Up = 2;
		public const int32 Down = 3;
	}

	public static class TableFlags
	{
		public const int32 Resizable = 1 << 0;
		public const int32 NoSavedSettings = 1 << 4;
		public const int32 RowBg = 1 << 6;
		public const int32 BordersInnerH = 1 << 7;
		public const int32 BordersInnerV = 1 << 9;
		public const int32 BordersOuter = 1280;
		public const int32 SizingFixedFit = 1 << 13;
		public const int32 SizingStretchProp = 3 << 13;
		public const int32 ScrollY = 33554432;
	}

	public static class ColumnFlags
	{
		public const int32 WidthStretch = 1 << 3;
		public const int32 WidthFixed = 1 << 4;
	}

	public static class InputFlags
	{
		public const int32 EnterReturnsTrue = 1 << 6;
		public const int32 ReadOnly = 1 << 9;
		public const int32 AutoSelectAll = 1 << 12;
	}

	public static class SelectableFlags
	{
		public const int32 NoAutoClosePopups = 1 << 0;
		public const int32 SpanAllColumns = 1 << 1;
		public const int32 AllowDoubleClick = 1 << 2;
	}

	public static class HoveredFlags
	{
		public const int32 ChildWindows = 1 << 0;
		public const int32 RootWindow = 1 << 1;
		public const int32 AllowWhenBlockedByActiveItem = 1 << 7;
		public const int32 AllowWhenDisabled = 1 << 10;
	}

	public static class DockFlags
	{
		public const int32 PassthruCentralNode = 1 << 3;
		public const int32 AutoHideTabBar = 1 << 6;
		public const int32 DockSpace = 1 << 10;
	}

	public static class ColorFlags
	{
		public const int32 NoAlpha = 1 << 1;
		public const int32 AlphaBar = 1 << 16;
		public const int32 NoInputs = 1 << 5;
		public const int32 NoLabel = 1 << 7;
		public const int32 HDR = 1 << 19;
		public const int32 Float = 1 << 24;
	}

	public static class Key
	{
		public const int32 Tab = 512;
		public const int32 Home = 519;
		public const int32 End = 520;
		public const int32 Delete = 522;
		public const int32 Backspace = 523;
		public const int32 Space = 524;
		public const int32 Enter = 525;
		public const int32 Escape = 526;
		public const int32 LeftCtrl = 527;
		public const int32 LeftShift = 528;
		public const int32 LeftAlt = 529;
		public const int32 Zero = 536;
		public const int32 One = 537;
		public const int32 Two = 538;
		public const int32 Three = 539;
		public const int32 Nine = 545;
		public const int32 A = 546;
		public const int32 B = 547;
		public const int32 C = 548;
		public const int32 D = 549;
		public const int32 E = 550;
		public const int32 F = 551;
		public const int32 G = 552;
		public const int32 H = 553;
		public const int32 I = 554;
		public const int32 J = 555;
		public const int32 K = 556;
		public const int32 L = 557;
		public const int32 M = 558;
		public const int32 N = 559;
		public const int32 O = 560;
		public const int32 P = 561;
		public const int32 Q = 562;
		public const int32 R = 563;
		public const int32 S = 564;
		public const int32 T = 565;
		public const int32 V = 567;
		public const int32 W = 568;
		public const int32 X = 569;
		public const int32 Y = 570;
		public const int32 Z = 571;
		public const int32 F1 = 572;
		public const int32 F2 = 573;
		public const int32 F5 = 576;
		public const int32 Minus = 598;
		public const int32 Period = 599;
		public const int32 Equal = 602;
		public const int32 LeftBracket = 603;
		public const int32 RightBracket = 605;
		public const int32 Keypad0 = 612;
		public const int32 Keypad1 = 613;
		public const int32 Keypad3 = 615;
		public const int32 Keypad5 = 617;
		public const int32 Keypad7 = 619;
		public const int32 Keypad9 = 621;
		public const int32 KeypadDecimal = 622;
		public const int32 KeypadSubtract = 625;
		public const int32 KeypadAdd = 626;
		public const int32 KeypadEnter = 627;
		public const int32 ModCtrl = 4096;
		public const int32 ModShift = 8192;
	}

	public const int32 PopupMouseButtonRight = 2 << 2;
	public const int32 ChildBorders = 1 << 0;
	public const int32 SliderAlwaysClamp = 1536;

	// ---- backend (native/tessera_native.cpp) ----
	[CLink] public static extern bool tn_imgui_init(void* window, char8* iniPath, float uiScale);
	[CLink] public static extern void tn_imgui_shutdown();
	[CLink] public static extern bool tn_imgui_event(void* event);
	[CLink] public static extern void tn_imgui_new_frame();
	[CLink] public static extern void tn_imgui_render(uint16 viewId);
	[CLink] public static extern void tn_imgui_push_mono_font();
	[CLink] public static extern void* tn_imgui_add_font(void* data, int32 size);
	[CLink] public static extern void tn_imgui_push_font(void* font, float size);
	[CLink] public static extern int32 tn_imgui_capture_flags();
	[CLink] public static extern bool tn_imgui_slider_float(char8* label, float* value, float min, float max, char8* format);
	[CLink] static extern int32 tn_imgui_color_count();
	[CLink] static extern char8* tn_imgui_color_name(int32 index);
	[CLink] static extern void tn_imgui_get_color(int32 index, float* rgba);
	[CLink] static extern void tn_imgui_set_color(int32 index, float* rgba);
	[CLink] static extern void tn_imgui_base_colors(bool light);

	/// The interface's colours (Col), for themes: how many, each one's name ("WindowBg"), reading and setting one,
	/// and starting again from ImGui's own dark or light colours.
	public static int32 StyleColorCount => tn_imgui_color_count();
	public static StringView StyleColorName(int32 index) => .(tn_imgui_color_name(index));
	public static Color GetStyleColor(int32 index)
	{
		Color color = default;
		tn_imgui_get_color(index, &color.r);
		return color;
	}

	public static void SetStyleColor(int32 index, Color color)
	{
		var color;
		tn_imgui_set_color(index, &color.r);
	}

	public static void StyleColorsBase(bool light) => tn_imgui_base_colors(light);
	[CLink] public static extern void tn_gizmo_begin(float x, float y, float width, float height, bool orthographic);
	[CLink] public static extern bool tn_gizmo_manipulate(float* view, float* projection, int32 operation, bool local, float* matrix, float* snap);
	[CLink] public static extern bool tn_gizmo_is_using();
	[CLink] public static extern bool tn_gizmo_is_over();

	// ---- cimgui ----
	[CLink] static extern bool igBegin(char8* name, bool* open, int32 flags);
	[CLink] static extern void igEnd();
	[CLink] static extern bool igBeginChild_Str(char8* id, Vec2 size, int32 childFlags, int32 windowFlags);
	[CLink] static extern void igEndChild();
	[CLink] static extern void igTextUnformatted(char8* text, char8* textEnd);
	[CLink] static extern void igTextColored(Vec4 color, char8* fmt, ...);
	[CLink] static extern void igTextDisabled(char8* fmt, ...);
	[CLink] static extern void igTextWrapped(char8* fmt, ...);
	[CLink] static extern void igBulletText(char8* fmt, ...);
	[CLink] static extern bool igButton(char8* label, Vec2 size);
	[CLink] static extern bool igSmallButton(char8* label);
	[CLink] static extern double igGetTime();
	[CLink] static extern bool igInvisibleButton(char8* id, Vec2 size, int32 flags);
	[CLink] static extern void igSameLine(float offset, float spacing);
	[CLink] static extern void igSeparator();
	[CLink] static extern void igSeparatorText(char8* label);
	[CLink] static extern void igSpacing();
	[CLink] static extern void igNewLine();
	[CLink] static extern void igDummy(Vec2 size);
	[CLink] static extern void igIndent(float width);
	[CLink] static extern void igUnindent(float width);
	[CLink] static extern void igBeginGroup();
	[CLink] static extern void igEndGroup();
	[CLink] static extern bool igCheckbox(char8* label, bool* value);
	[CLink] static extern bool igDragFloat(char8* label, float* v, float speed, float min, float max, char8* format, int32 flags);
	[CLink] static extern bool igDragFloat3(char8* label, float* v, float speed, float min, float max, char8* format, int32 flags);
	[CLink] static extern bool igDragFloat2(char8* label, float* v, float speed, float min, float max, char8* format, int32 flags);
	[CLink] static extern bool igDragFloat4(char8* label, float* v, float speed, float min, float max, char8* format, int32 flags);
	[CLink] static extern bool igDragInt(char8* label, int32* v, float speed, int32 min, int32 max, char8* format, int32 flags);
	[CLink] static extern bool igSliderFloat(char8* label, float* v, float min, float max, char8* format, int32 flags);
	[CLink] static extern bool igInputText(char8* label, char8* buffer, uint size, int32 flags, void* callback, void* userData);
	[CLink] static extern bool igInputTextMultiline(char8* label, char8* buffer, uint size, Vec2 boxSize, int32 flags, void* callback, void* userData);
	[CLink] static extern bool igInputTextWithHint(char8* label, char8* hint, char8* buffer, uint size, int32 flags, void* callback, void* userData);
	[CLink] static extern bool igInputInt(char8* label, int32* v, int32 step, int32 stepFast, int32 flags);
	[CLink] static extern bool igColorEdit3(char8* label, float* color, int32 flags);
	[CLink] static extern bool igColorEdit4(char8* label, float* color, int32 flags);
	[CLink] static extern bool igBeginCombo(char8* label, char8* preview, int32 flags);
	[CLink] static extern void igEndCombo();
	[CLink] static extern bool igSelectable_Bool(char8* label, bool selected, int32 flags, Vec2 size);
	[CLink] static extern bool igTreeNodeEx_Str(char8* label, int32 flags);
	[CLink] static extern void igTreePop();
	[CLink] static extern void igSetNextItemOpen(bool open, int32 cond);
	[CLink] static extern bool igCollapsingHeader_TreeNodeFlags(char8* label, int32 flags);
	[CLink] static extern bool igBeginMainMenuBar();
	[CLink] static extern void igEndMainMenuBar();
	[CLink] static extern bool igBeginMenuBar();
	[CLink] static extern void igEndMenuBar();
	[CLink] static extern bool igBeginMenu(char8* label, bool enabled);
	[CLink] static extern void igEndMenu();
	[CLink] static extern bool igMenuItem_Bool(char8* label, char8* shortcut, bool selected, bool enabled);
	[CLink] static extern bool igBeginPopup(char8* id, int32 flags);
	[CLink] static extern bool igBeginPopupContextItem(char8* id, int32 flags);
	[CLink] static extern bool igBeginPopupContextWindow(char8* id, int32 flags);
	[CLink] static extern bool igBeginPopupModal(char8* name, bool* open, int32 flags);
	[CLink] static extern void igEndPopup();
	[CLink] static extern bool igOpenPopup_Str(char8* id, int32 flags);
	[CLink] static extern void igCloseCurrentPopup();
	[CLink] static extern void igImage(TextureRef texture, Vec2 size, Vec2 uv0, Vec2 uv1);
	[CLink] static extern Vec2 igGetContentRegionAvail();
	[CLink] static extern Vec2 igGetCursorScreenPos();
	[CLink] static extern void igSetCursorScreenPos(Vec2 pos);
	[CLink] static extern void igSetCursorPosX(float x);
	[CLink] static extern void igSetCursorPosY(float y);
	[CLink] static extern float igGetCursorPosX();
	[CLink] static extern float igGetCursorPosY();
	[CLink] static extern Vec2 igGetWindowPos();
	[CLink] static extern Vec2 igGetWindowSize();
	[CLink] static extern uint32 igGetWindowDockID();
	[CLink] static extern void igSetNextWindowDockID(uint32 id, int32 condition);
	[CLink] static extern float igGetWindowWidth();
	[CLink] static extern bool igIsWindowHovered(int32 flags);
	[CLink] static extern bool igIsWindowFocused(int32 flags);
	[CLink] static extern void igSetWindowFocus_Str(char8* name);
	[CLink] static extern bool igIsItemClicked(int32 button);
	[CLink] static extern bool igIsItemHovered(int32 flags);
	[CLink] static extern bool igIsItemActive();
	[CLink] static extern bool igIsItemToggledOpen();
	[CLink] static extern bool igIsItemDeactivatedAfterEdit();
	[CLink] static extern bool igIsItemActivated();
	[CLink] static extern void igClearActiveID();
	[CLink] static extern bool igIsAnyItemActive();
	[CLink] static extern bool igIsMouseDown_Nil(int32 button);
	[CLink] static extern bool igIsMouseClicked_Bool(int32 button, bool repeat_);
	[CLink] static extern bool igIsMouseReleased_Nil(int32 button);
	[CLink] static extern bool igIsMouseDoubleClicked_Nil(int32 button);
	[CLink] static extern bool igIsMouseDragging(int32 button, float threshold);
	[CLink] static extern Vec2 igGetMousePos();
	[CLink] static extern Vec2 igGetItemRectMin();
	[CLink] static extern Vec2 igGetItemRectMax();
	[CLink] static extern void* igGetIO_Nil();
	[CLink] static extern void ImGuiIO_AddMousePosEvent(void* io, float x, float y);
	[CLink] static extern void ImGuiIO_AddMouseButtonEvent(void* io, int32 button, bool down);
	[CLink] static extern bool igIsKeyPressed_Bool(int32 key, bool repeat_);
	[CLink] static extern bool igIsKeyDown_Nil(int32 key);
	[CLink] static extern void igPushID_Str(char8* id);
	[CLink] static extern void igPushID_Int(int32 id);
	[CLink] static extern void igPushID_Ptr(void* id);
	[CLink] static extern void igPopID();
	[CLink] static extern uint32 igGetID_Str(char8* id);
	[CLink] static extern void igPushStyleColor_Vec4(int32 index, Vec4 color);
	[CLink] static extern void igPopStyleColor(int32 count);
	[CLink] static extern void igPushStyleVar_Vec2(int32 index, Vec2 value);
	[CLink] static extern void igPushStyleVar_Float(int32 index, float value);
	[CLink] static extern void igPopStyleVar(int32 count);
	[CLink] static extern void igPopFont();
	[CLink] static extern void igSetNextItemWidth(float width);
	[CLink] static extern void igSetNextWindowPos(Vec2 pos, int32 cond, Vec2 pivot);
	[CLink] static extern void igSetNextWindowSize(Vec2 size, int32 cond);
	[CLink] static extern void igSetNextWindowFocus();
	[CLink] static extern void igSetNextWindowBgAlpha(float alpha);
	[CLink] static extern uint32 igDockSpaceOverViewport(uint32 dockspaceId, Viewport* viewport, int32 flags, void* windowClass);
	[CLink] static extern Viewport* igGetMainViewport();
	[CLink] static extern uint32 igDockBuilderAddNode(uint32 nodeId, int32 flags);
	[CLink] static extern void igDockBuilderRemoveNode(uint32 nodeId);
	[CLink] static extern void igDockBuilderSetNodeSize(uint32 nodeId, Vec2 size);
	[CLink] static extern uint32 igDockBuilderSplitNode(uint32 nodeId, int32 dir, float ratio, uint32* outAtDir, uint32* outOpposite);
	[CLink] static extern void igDockBuilderDockWindow(char8* windowName, uint32 nodeId);
	[CLink] static extern void igDockBuilderFinish(uint32 nodeId);
	[CLink] static extern void* igDockBuilderGetNode(uint32 nodeId);
	[CLink] static extern bool igBeginTable(char8* id, int32 columns, int32 flags, Vec2 outerSize, float innerWidth);
	[CLink] static extern void igEndTable();
	[CLink] static extern void igTableNextRow(int32 flags, float minHeight);
	[CLink] static extern void igTableHeadersRow();
	[CLink] static extern bool igTableNextColumn();
	[CLink] static extern void igTableSetupColumn(char8* label, int32 flags, float width, uint32 userId);
	[CLink] static extern void igBeginDisabled(bool disabled);
	[CLink] static extern void igEndDisabled();
	[CLink] static extern void igSetTooltip(char8* fmt, ...);
	[CLink] static extern void igAlignTextToFramePadding();
	[CLink] static extern float igGetFrameHeight();
	[CLink] static extern float igGetTextLineHeight();
	[CLink] static extern Vec2 igCalcTextSize(char8* text, char8* textEnd, bool hideAfterHash, float wrapWidth);
	[CLink] static extern void igSetKeyboardFocusHere(int32 offset);
	[CLink] static extern void igSetItemDefaultFocus();
	[CLink] static extern bool igBeginDragDropSource(int32 flags);
	[CLink] static extern void igEndDragDropSource();
	[CLink] static extern bool igSetDragDropPayload(char8* type, void* data, uint size, int32 cond);
	[CRepr] struct DropRect { public Vec2 min; public Vec2 max; }
	[CLink] static extern bool igBeginDragDropTargetCustom(DropRect rect, uint32 id);
	[CLink] static extern Payload* igGetDragDropPayload();
	[CLink] static extern bool ImGuiPayload_IsDataType(Payload* payload, char8* type);
	[CLink] static extern bool igBeginDragDropTarget();
	[CLink] static extern void igEndDragDropTarget();
	[CLink] static extern Payload* igAcceptDragDropPayload(char8* type, int32 flags);
	[CLink] static extern void igShowDemoWindow(bool* open);
	[CLink] static extern void igSetScrollHereY(float ratio);
	[CLink] static extern float igGetScrollY();
	[CLink] static extern float igGetScrollMaxY();
	[CLink] static extern void igProgressBar(float fraction, Vec2 size, char8* overlay);
	[CLink] static extern void* igGetWindowDrawList();
	[CLink] static extern void ImDrawList_AddLine(void* list, Vec2 a, Vec2 b, uint32 color, float thickness);
	[CLink] static extern void ImDrawList_AddRect(void* list, Vec2 min, Vec2 max, uint32 color, float rounding, float thickness, int32 flags);
	[CLink] static extern void ImDrawList_AddRectFilled(void* list, Vec2 min, Vec2 max, uint32 color, float rounding, int32 flags);
	[CLink] static extern void ImDrawList_AddImage(void* list, TextureRef texture, Vec2 min, Vec2 max, Vec2 uv0, Vec2 uv1, uint32 color);
	[CLink] static extern void ImDrawList_AddImageQuad(void* list, TextureRef texture, Vec2 p1, Vec2 p2, Vec2 p3, Vec2 p4, Vec2 uv1, Vec2 uv2, Vec2 uv3, Vec2 uv4, uint32 color);
	[CLink] static extern void ImDrawList_AddTriangleFilled(void* list, Vec2 a, Vec2 b, Vec2 c, uint32 color);
	[CLink] static extern void ImDrawList_AddQuadFilled(void* list, Vec2 a, Vec2 b, Vec2 c, Vec2 d, uint32 color);
	[CLink] static extern void ImDrawList_AddCircleFilled(void* list, Vec2 center, float radius, uint32 color, int32 segments);
	[CLink] static extern void ImDrawList_AddCircle(void* list, Vec2 center, float radius, uint32 color, int32 segments, float thickness);
	[CLink] static extern void ImDrawList_PushClipRect(void* list, Vec2 min, Vec2 max, bool intersect);
	[CLink] static extern void ImDrawList_PopClipRect(void* list);
	[CLink] static extern void igSetScrollY_Float(float y);
	[CLink] static extern void ImDrawList_AddText_Vec2(void* list, Vec2 pos, uint32 color, char8* text, char8* textEnd);

	// ---- wrappers ----
	public static bool Begin(char8* name, bool* open = null, int32 flags = 0) => igBegin(name, open, flags);
	public static void End() => igEnd();
	public static bool BeginChild(char8* id, Vec2 size = .(0, 0), int32 childFlags = 0, int32 windowFlags = 0) => igBeginChild_Str(id, size, childFlags, windowFlags);
	public static void EndChild() => igEndChild();

	public static void Text(StringView text)
	{
		igTextUnformatted(text.Ptr, text.Ptr + text.Length);
	}

	public static void TextColored(Color color, char8* text) => igTextColored(.(color.r, color.g, color.b, color.a), "%s", text);
	public static void TextDisabled(char8* text) => igTextDisabled("%s", text);
	public static void TextWrapped(char8* text) => igTextWrapped("%s", text);
	public static void BulletText(char8* text) => igBulletText("%s", text);
	[CLink] static extern void igPushTextWrapPos(float wrapLocalPosX);
	[CLink] static extern void igPopTextWrapPos();
	[CLink] static extern bool igRadioButton_Bool(char8* label, bool active);
	[CLink] static extern void igSetClipboardText(char8* text);
	/// Text drawn until PopTextWrapPos wraps at this x within the window; 0 wraps at the window's edge.
	public static void PushTextWrapPos(float wrapX = 0) => igPushTextWrapPos(wrapX);
	public static void PopTextWrapPos() => igPopTextWrapPos();
	/// A round option button; true when it was just pressed.
	public static bool RadioButton(char8* label, bool active) => igRadioButton_Bool(label, active);
	public static void SetClipboardText(char8* text) => igSetClipboardText(text);
	public static bool Button(char8* label, Vec2 size = .(0, 0)) => igButton(label, size);
	public static bool SmallButton(char8* label) => igSmallButton(label);
	/// Seconds since ImGui started.
	public static double GetTime() => igGetTime();
	public static bool InvisibleButton(char8* id, Vec2 size) => igInvisibleButton(id, size, 0);
	public static void SameLine(float offset = 0, float spacing = -1) => igSameLine(offset, spacing);
	public static void Separator() => igSeparator();
	public static void SeparatorText(char8* label) => igSeparatorText(label);
	public static void Spacing() => igSpacing();
	/// Ends a line of items placed with SameLine.
	public static void NewLine() => igNewLine();
	public static void Dummy(Vec2 size) => igDummy(size);
	public static void Indent(float width = 0) => igIndent(width);
	public static void Unindent(float width = 0) => igUnindent(width);
	public static void BeginGroup() => igBeginGroup();
	public static void EndGroup() => igEndGroup();
	public static bool Checkbox(char8* label, ref bool value) => igCheckbox(label, &value);
	public static bool DragFloat(char8* label, ref float v, float speed = 0.1f, float min = 0, float max = 0, char8* format = "%.3f") => igDragFloat(label, &v, speed, min, max, format, 0);
	public static bool DragFloat3(char8* label, ref Vector3 v, float speed = 0.1f, float min = 0, float max = 0, char8* format = "%.3f") => igDragFloat3(label, &v.x, speed, min, max, format, 0);
	public static bool DragInt(char8* label, ref int32 v, float speed = 1, int32 min = 0, int32 max = 0) => igDragInt(label, &v, speed, min, max, "%d", 0);
	/// A slider between two numbers. Double-click it (or Ctrl+click) to type the number instead.
	public static bool SliderFloat(char8* label, ref float v, float min, float max, char8* format = "%.3f") => tn_imgui_slider_float(label, &v, min, max, format);
	public static bool DragFloat2(char8* label, float* v, float speed = 0.1f) => igDragFloat2(label, v, speed, 0, 0, "%.3f", 0);
	public static bool DragFloat4(char8* label, float* v, float speed = 0.1f) => igDragFloat4(label, v, speed, 0, 0, "%.3f", 0);
	public static bool InputInt(char8* label, ref int32 v) => igInputInt(label, &v, 1, 10, 0);
	public static bool ColorEdit3(char8* label, ref Color color, int32 flags = 0) => igColorEdit3(label, &color.r, flags);
	public static bool ColorEdit4(char8* label, ref Color color, int32 flags = 0) => igColorEdit4(label, &color.r, flags);

	/// Edits a String of several lines in place, in a box of the given size (0: the default). Returns true when the
	/// text changed. Holds up to capacity characters.
	public static bool InputTextMultiline(char8* label, String text, Vec2 size = .(0, 0), int32 flags = 0, int capacity = 4096)
	{
		let buffer = scope char8[capacity];
		let count = Math.Min(text.Length, capacity - 1);
		Internal.MemCpy(buffer.Ptr, text.Ptr, count);
		buffer[count] = 0;
		let changed = igInputTextMultiline(label, buffer.Ptr, (uint)capacity, size, flags, null, null);
		if (changed)
		{
			text.Clear();
			text.Append(buffer.Ptr);
		}
		return changed;
	}

	/// Edits a String in place. Returns true when the text changed (or Enter was pressed with EnterReturnsTrue).
	public static bool InputText(char8* label, String text, int32 flags = 0, char8* hint = null)
	{
		char8[512] buffer = default;
		let count = Math.Min(text.Length, buffer.Count - 1);
		Internal.MemCpy(&buffer, text.Ptr, count);
		bool changed;
		if (hint != null)
			changed = igInputTextWithHint(label, hint, &buffer, (uint)buffer.Count, flags, null, null);
		else
			changed = igInputText(label, &buffer, (uint)buffer.Count, flags, null, null);
		if (changed)
		{
			text.Clear();
			text.Append(&buffer);
		}
		return changed;
	}

	public static bool BeginCombo(char8* label, char8* preview) => igBeginCombo(label, preview, 0);
	public static void EndCombo() => igEndCombo();
	public static bool Selectable(char8* label, bool selected = false, int32 flags = 0, Vec2 size = .(0, 0)) => igSelectable_Bool(label, selected, flags, size);
	public static bool TreeNode(char8* label, int32 flags = 0) => igTreeNodeEx_Str(label, flags);
	public static void TreePop() => igTreePop();
	public static void SetNextItemOpen(bool open, int32 cond = 0) => igSetNextItemOpen(open, cond);
	public static bool CollapsingHeader(char8* label, int32 flags = 0) => igCollapsingHeader_TreeNodeFlags(label, flags);
	public static bool BeginMainMenuBar() => igBeginMainMenuBar();
	public static void EndMainMenuBar() => igEndMainMenuBar();
	public static bool BeginMenuBar() => igBeginMenuBar();
	public static void EndMenuBar() => igEndMenuBar();
	public static bool BeginMenu(char8* label, bool enabled = true) => igBeginMenu(label, enabled);
	public static void EndMenu() => igEndMenu();
	public static bool MenuItem(char8* label, char8* shortcut = null, bool selected = false, bool enabled = true) => igMenuItem_Bool(label, shortcut, selected, enabled);
	public static bool BeginPopup(char8* id, int32 flags = 0) => igBeginPopup(id, flags);
	public static bool BeginPopupContextItem(char8* id = null) => igBeginPopupContextItem(id, 1);
	public static bool BeginPopupContextWindow(char8* id = null, int32 flags = 1) => igBeginPopupContextWindow(id, flags);
	public static bool BeginPopupModal(char8* name, bool* open = null, int32 flags = 0) => igBeginPopupModal(name, open, flags);
	public static void EndPopup() => igEndPopup();
	public static void OpenPopup(char8* id) => igOpenPopup_Str(id, 0);
	public static void CloseCurrentPopup() => igCloseCurrentPopup();

	/// Draws a bgfx texture. Set opaque for render targets so their alpha channel is ignored.
	public static void Image(uint16 textureIndex, Vec2 size, Vec2 uv0 = .(0, 0), Vec2 uv1 = .(1, 1), bool opaque = true)
	{
		TextureRef texture = default;
		texture.texId = (uint64)textureIndex + 1;
		if (opaque)
			texture.texId |= (uint64)1 << 32;
		igImage(texture, size, uv0, uv1);
	}

	/// Paints a bgfx texture at a fixed place in the window without taking part in layout.
	public static void DrawImage(uint16 textureIndex, Vec2 min, Vec2 max, bool opaque = true)
	{
		DrawImage(textureIndex, min, max, .White, opaque);
	}

	/// Paints a bgfx texture tinted by a colour (its alpha fades the picture).
	public static void DrawImage(uint16 textureIndex, Vec2 min, Vec2 max, Color tint, bool opaque = false)
	{
		TextureRef texture = default;
		texture.texId = (uint64)textureIndex + 1;
		if (opaque)
			texture.texId |= (uint64)1 << 32;
		ImDrawList_AddImage(igGetWindowDrawList(), texture, min, max, .(0, 0), .(1, 1), tint.ToABGR());
	}

	/// Shows a picture the graphics card drew (a render target, or a copy of one), the right way up: OpenGL keeps
	/// those bottom row first. uv0 to uv1 picks part of it, counted from its top left.
	public static void Picture(uint16 textureIndex, Vec2 size, Vec2 uv0 = .(0, 0), Vec2 uv1 = .(1, 1))
	{
		var from = uv0, to = uv1;
		PictureUV(ref from, ref to);
		Image(textureIndex, size, from, to, true);
	}

	/// Paints a picture the graphics card drew at a fixed place in the window, the right way up (see Picture).
	public static void DrawPicture(uint16 textureIndex, Vec2 min, Vec2 max, Vec2 uv0 = .(0, 0), Vec2 uv1 = .(1, 1), bool opaque = true)
	{
		var from = uv0, to = uv1;
		PictureUV(ref from, ref to);
		TextureRef texture = default;
		texture.texId = (uint64)textureIndex + 1;
		if (opaque)
			texture.texId |= (uint64)1 << 32;
		ImDrawList_AddImage(igGetWindowDrawList(), texture, min, max, from, to, 0xffffffff);
	}

	static void PictureUV(ref Vec2 from, ref Vec2 to)
	{
		if (!Gfx.OriginBottomLeft)
			return;
		from.y = 1 - from.y;
		to.y = 1 - to.y;
	}

	/// Rotated textured quad, with angle in radians about its centre.
	public static void DrawImageRotated(uint16 textureIndex, Vec2 center, Vec2 size, float angle)
	{
		TextureRef texture = default;
		texture.texId = (uint64)textureIndex + 1;
		let c = Math.Cos(angle);
		let s = Math.Sin(angle);
		let x = Vec2(c * size.x * 0.5f, s * size.x * 0.5f);
		let y = Vec2(-s * size.y * 0.5f, c * size.y * 0.5f);
		ImDrawList_AddImageQuad(igGetWindowDrawList(), texture,
			.(center.x - x.x - y.x, center.y - x.y - y.y), .(center.x + x.x - y.x, center.y + x.y - y.y),
			.(center.x + x.x + y.x, center.y + x.y + y.y), .(center.x - x.x + y.x, center.y - x.y + y.y),
			.(0, 0), .(1, 0), .(1, 1), .(0, 1), 0xffffffff);
	}

	public static Vec2 GetContentRegionAvail() => igGetContentRegionAvail();
	public static Vec2 GetCursorScreenPos() => igGetCursorScreenPos();
	/// The last item drawn: its top left and bottom right corners on the screen.
	public static Vec2 GetItemRectMin() => igGetItemRectMin();
	public static Vec2 GetItemRectMax() => igGetItemRectMax();
	/// Queues the mouse moving to a point, as the mouse itself would (editor self-tests drive the interface with it).
	public static void QueueMousePos(float x, float y) => ImGuiIO_AddMousePosEvent(igGetIO_Nil(), x, y);
	/// Queues a mouse button going down or up.
	public static void QueueMouseButton(int32 button, bool down) => ImGuiIO_AddMouseButtonEvent(igGetIO_Nil(), button, down);
	public static void SetCursorScreenPos(Vec2 pos) => igSetCursorScreenPos(pos);
	public static void SetCursorPosX(float x) => igSetCursorPosX(x);
	public static void SetCursorPosY(float y) => igSetCursorPosY(y);
	public static float GetCursorPosX() => igGetCursorPosX();
	public static float GetCursorPosY() => igGetCursorPosY();
	public static Vec2 GetWindowPos() => igGetWindowPos();
	public static Vec2 GetWindowSize() => igGetWindowSize();
	public static uint32 GetWindowDockID() => igGetWindowDockID();
	public static void SetNextWindowDockID(uint32 id) => igSetNextWindowDockID(id, 1);
	public static float GetWindowWidth() => igGetWindowWidth();
	public static bool IsWindowHovered(int32 flags = 0) => igIsWindowHovered(flags);
	public static bool IsWindowFocused(int32 flags = 0) => igIsWindowFocused(flags);
	public static void SetWindowFocus(char8* name) => igSetWindowFocus_Str(name);
	public static bool IsItemClicked(int32 button = 0) => igIsItemClicked(button);
	public static bool IsItemHovered(int32 flags = 0) => igIsItemHovered(flags);
	public static bool IsItemActive() => igIsItemActive();
	public static bool IsItemToggledOpen() => igIsItemToggledOpen();
	public static bool IsItemDeactivatedAfterEdit() => igIsItemDeactivatedAfterEdit();
	/// The last item was clicked or focused this frame.
	public static bool IsItemActivated() => igIsItemActivated();
	/// Lets go of whatever control has the keyboard.
	public static void ClearActiveID() => igClearActiveID();
	public static bool IsAnyItemActive() => igIsAnyItemActive();
	public static bool IsMouseDown(int32 button) => igIsMouseDown_Nil(button);
	public static bool IsMouseClicked(int32 button) => igIsMouseClicked_Bool(button, false);
	public static bool IsMouseReleased(int32 button) => igIsMouseReleased_Nil(button);
	public static bool IsMouseDoubleClicked(int32 button) => igIsMouseDoubleClicked_Nil(button);
	public static bool IsMouseDragging(int32 button, float threshold = -1) => igIsMouseDragging(button, threshold);
	public static Vec2 GetMousePos() => igGetMousePos();
	public static bool IsKeyPressed(int32 key, bool repeat_ = false) => igIsKeyPressed_Bool(key, repeat_);
	public static bool IsKeyDown(int32 key) => igIsKeyDown_Nil(key);
	public static void PushID(char8* id) => igPushID_Str(id);
	public static void PushID(int32 id) => igPushID_Int(id);
	public static void PushID(void* id) => igPushID_Ptr(id);
	public static void PopID() => igPopID();
	public static uint32 GetID(char8* id) => igGetID_Str(id);
	public static void PushStyleColor(int32 index, Color color) => igPushStyleColor_Vec4(index, .(color.r, color.g, color.b, color.a));
	public static void PopStyleColor(int32 count = 1) => igPopStyleColor(count);
	public static void PushStyleVar(int32 index, Vec2 value) => igPushStyleVar_Vec2(index, value);
	public static void PushStyleVar(int32 index, float value) => igPushStyleVar_Float(index, value);
	public static void PopStyleVar(int32 count = 1) => igPopStyleVar(count);
	public static void PushMonoFont() => tn_imgui_push_mono_font();
	[CLink] static extern void igPushFont(void* font, float size);
	/// Switches to the default font at a pixel size until PopFont.
	public static void PushFontSize(float size) => igPushFont(null, size);
	public static void PopFont() => igPopFont();
	public static void SetNextItemWidth(float width) => igSetNextItemWidth(width);
	public static void SetNextWindowPos(Vec2 pos, int32 cond = 0, Vec2 pivot = .(0, 0)) => igSetNextWindowPos(pos, cond, pivot);
	public static void SetNextWindowSize(Vec2 size, int32 cond = 0) => igSetNextWindowSize(size, cond);
	public static void SetNextWindowFocus() => igSetNextWindowFocus();
	public static void SetNextWindowBgAlpha(float alpha) => igSetNextWindowBgAlpha(alpha);
	public static uint32 DockSpaceOverViewport(uint32 id = 0, int32 flags = 0) => igDockSpaceOverViewport(id, igGetMainViewport(), flags, null);
	public static Viewport* GetMainViewport() => igGetMainViewport();
	public static uint32 DockBuilderAddNode(uint32 id, int32 flags = 0) => igDockBuilderAddNode(id, flags);
	public static void DockBuilderRemoveNode(uint32 id) => igDockBuilderRemoveNode(id);
	public static void DockBuilderSetNodeSize(uint32 id, Vec2 size) => igDockBuilderSetNodeSize(id, size);
	public static uint32 DockBuilderSplitNode(uint32 id, int32 dir, float ratio, out uint32 atDir, out uint32 opposite)
	{
		atDir = 0;
		opposite = 0;
		return igDockBuilderSplitNode(id, dir, ratio, &atDir, &opposite);
	}

	public static void DockBuilderDockWindow(char8* name, uint32 id) => igDockBuilderDockWindow(name, id);
	public static void DockBuilderFinish(uint32 id) => igDockBuilderFinish(id);
	public static bool DockBuilderHasNode(uint32 id) => igDockBuilderGetNode(id) != null;
	public static bool BeginTable(char8* id, int32 columns, int32 flags = 0) => igBeginTable(id, columns, flags, .(0, 0), 0);
	public static void EndTable() => igEndTable();
	public static bool BeginTable(char8* id, int32 columns, int32 flags, Vec2 size) => igBeginTable(id, columns, flags, size, 0);
	public static void TableHeadersRow() => igTableHeadersRow();
	public static void TableNextRow() => igTableNextRow(0, 0);
	public static bool TableNextColumn() => igTableNextColumn();
	public static void TableSetupColumn(char8* label, int32 flags = 0, float width = 0) => igTableSetupColumn(label, flags, width, 0);
	public static void BeginDisabled(bool disabled = true) => igBeginDisabled(disabled);
	public static void EndDisabled() => igEndDisabled();
	public static void SetTooltip(char8* text) => igSetTooltip("%s", text);
	public static void AlignTextToFramePadding() => igAlignTextToFramePadding();
	public static float GetFrameHeight() => igGetFrameHeight();
	public static float GetTextLineHeight() => igGetTextLineHeight();
	public static Vec2 CalcTextSize(char8* text) => igCalcTextSize(text, null, false, -1);
	/// The size of text broken into lines no wider than wrapWidth.
	public static Vec2 CalcTextSizeWrapped(char8* text, float wrapWidth) => igCalcTextSize(text, null, false, Math.Max(wrapWidth, 1));
	[CLink] static extern void* igGetFont();
	[CLink] static extern float igGetFontSize();
	/// The size of the font in use, in pixels.
	public static float GetFontSize() => igGetFontSize();
	[CLink] static extern void ImDrawList_AddText_FontPtr(void* list, void* font, float fontSize, Vec2 pos, uint32 color, char8* text, char8* textEnd, float wrapWidth, Vec4* clip);
	/// Text broken into lines no wider than wrapWidth, in the current font and size.
	public static void DrawTextWrapped(Vec2 pos, Color color, char8* text, float wrapWidth) => ImDrawList_AddText_FontPtr(igGetWindowDrawList(), igGetFont(), igGetFontSize(), pos, color.ToABGR(), text, null, Math.Max(wrapWidth, 1), null);
	public static void SetKeyboardFocusHere(int32 offset = 0) => igSetKeyboardFocusHere(offset);
	public static void SetItemDefaultFocus() => igSetItemDefaultFocus();
	public static bool BeginDragDropSource(int32 flags = 0) => igBeginDragDropSource(flags);
	public static void EndDragDropSource() => igEndDragDropSource();
	public static bool SetDragDropPayload(char8* type, void* data, int size) => igSetDragDropPayload(type, data, (uint)size, 0);
	public static Payload* GetDragDropPayload() => igGetDragDropPayload();
	public static bool PayloadIsType(Payload* payload, char8* type) => ImGuiPayload_IsDataType(payload, type);
	public static bool BeginDragDropTargetCustom(Vec2 min, Vec2 max, uint32 id) => igBeginDragDropTargetCustom(.() { min = min, max = max }, id);
	public static bool BeginDragDropTarget() => igBeginDragDropTarget();
	public static void EndDragDropTarget() => igEndDragDropTarget();
	public static Payload* AcceptDragDropPayload(char8* type) => igAcceptDragDropPayload(type, 0);
	public static Payload* AcceptDragDropPayload(char8* type, int32 flags) => igAcceptDragDropPayload(type, flags);
	public static void ShowDemoWindow(bool* open = null) => igShowDemoWindow(open);
	public static void SetScrollHereY(float ratio = 0.5f) => igSetScrollHereY(ratio);
	public static float GetScrollY() => igGetScrollY();
	public static float GetScrollMaxY() => igGetScrollMaxY();
	public static void ProgressBar(float fraction, Vec2 size = .(-1, 0), char8* overlay = null) => igProgressBar(fraction, size, overlay);

	public static uint32 PackColor(Color c) => c.ToABGR();
	public static void DrawLine(Vec2 a, Vec2 b, Color color, float thickness = 1) => ImDrawList_AddLine(igGetWindowDrawList(), a, b, color.ToABGR(), thickness);
	public static void DrawRect(Vec2 min, Vec2 max, Color color, float rounding = 0, float thickness = 1) => ImDrawList_AddRect(igGetWindowDrawList(), min, max, color.ToABGR(), rounding, thickness, 0);
	public static void DrawRectFilled(Vec2 min, Vec2 max, Color color, float rounding = 0) => ImDrawList_AddRectFilled(igGetWindowDrawList(), min, max, color.ToABGR(), rounding, 0);
	public static void DrawTriangleFilled(Vec2 a, Vec2 b, Vec2 c, Color color) => ImDrawList_AddTriangleFilled(igGetWindowDrawList(), a, b, c, color.ToABGR());
	public static void DrawQuadFilled(Vec2 a, Vec2 b, Vec2 c, Vec2 d, Color color) => ImDrawList_AddQuadFilled(igGetWindowDrawList(), a, b, c, d, color.ToABGR());
	public static void DrawCircleFilled(Vec2 center, float radius, Color color) => ImDrawList_AddCircleFilled(igGetWindowDrawList(), center, radius, color.ToABGR(), 0);
	public static void DrawCircle(Vec2 center, float radius, Color color, float thickness = 1) => ImDrawList_AddCircle(igGetWindowDrawList(), center, radius, color.ToABGR(), 0, thickness);
	/// Limits what is drawn next to a rectangle (inside the current limit), until PopClipRect.
	public static void PushClipRect(Vec2 min, Vec2 max) => ImDrawList_PushClipRect(igGetWindowDrawList(), min, max, true);
	public static void PopClipRect() => ImDrawList_PopClipRect(igGetWindowDrawList());
	public static void SetScrollY(float y) => igSetScrollY_Float(y);
	public static void DrawText(Vec2 pos, Color color, char8* text) => ImDrawList_AddText_Vec2(igGetWindowDrawList(), pos, color.ToABGR(), text, null);
}
