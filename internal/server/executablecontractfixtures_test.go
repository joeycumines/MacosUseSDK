// Copyright 2026 Joseph Cumines
//
// Executable MCP and gRPC contract inventories used by the matrix tests.

package server

type executableToolContract struct {
	source       string
	handler      string
	effect       string
	proof        string
	macosUseRPCs []string
	externalRPCs []string
}

var executableToolContracts = map[string]executableToolContract{
	"screenshot": {
		source: "cuascreenshot.go", handler: "handleScreenshot", effect: "capture",
		proof:        "returned pixels and requested-region metadata",
		macosUseRPCs: []string{"CaptureScreenshot", "CaptureWindowScreenshot", "CaptureRegionScreenshot"},
	},
	"click": {
		source: "cua_input_handlers.go", handler: "cuaHandleClick", effect: "input mutation",
		proof: "owned target state delta", macosUseRPCs: []string{"CreateInput"},
	},
	"double_click": {
		source: "cua_input_handlers.go", handler: "handleDoubleClick", effect: "input mutation",
		proof: "owned target state delta", macosUseRPCs: []string{"CreateInput"},
	},
	"type": {
		source: "cua_input_handlers.go", handler: "handleType", effect: "input mutation",
		proof: "owned target value delta", macosUseRPCs: []string{"CreateInput"},
	},
	"keypress": {
		source: "cua_input_handlers.go", handler: "handleKeypress", effect: "input mutation",
		proof: "owned target state delta", macosUseRPCs: []string{"CreateInput"},
	},
	"scroll": {
		source: "cua_input_handlers.go", handler: "cuaHandleScroll", effect: "input mutation",
		proof: "owned target state delta", macosUseRPCs: []string{"CreateInput"},
	},
	"drag": {
		source: "cua_input_handlers.go", handler: "cuaHandleDrag", effect: "input mutation",
		proof: "owned target state delta", macosUseRPCs: []string{"CreateInput"},
	},
	"move": {
		source: "cua_input_handlers.go", handler: "handleMove", effect: "input mutation",
		proof: "cursor position delta", macosUseRPCs: []string{"CreateInput"},
	},
	"wait": {
		source: "cua_wait.go", handler: "handleWait", effect: "local wait",
		proof: "bounded elapsed time and cancellation",
	},
	"open_app": {
		source: "cua_application.go", handler: "handleOpenApp", effect: "application lifecycle mutation",
		proof:        "owned process identity and observed open disposition",
		macosUseRPCs: []string{"OpenApplication", "ActivateApplication"},
	},
	"list_apps": {
		source: "cua_application.go", handler: "handleListApps", effect: "query",
		proof: "installed bundles or live application and window resources", macosUseRPCs: []string{"ListApplicationBundles", "ListApplications", "ListWindows"},
	},
	"close_app": {
		source: "cua_application.go", handler: "handleCloseApp", effect: "application lifecycle mutation",
		proof:        "owned process disappearance",
		macosUseRPCs: []string{"CloseApplication"},
	},
	"find_elements": {
		source: "cua_element.go", handler: "cuaHandleFindElements", effect: "query",
		proof: "live AX resources", macosUseRPCs: []string{"FindElements"},
	},
	"click_element": {
		source: "cua_element.go", handler: "cuaHandleClickElement", effect: "AX mutation",
		proof: "owned target state delta", macosUseRPCs: []string{"ClickElement", "GetElement"},
	},
	"type_element": {
		source: "cua_element.go", handler: "handleTypeElement", effect: "AX or input mutation",
		proof:        "owned target value delta",
		macosUseRPCs: []string{"FocusWindow", "WriteElementValue", "GetElement", "GetElementActions"},
	},
	"read_element": {
		source: "cua_element.go", handler: "handleReadElement", effect: "query",
		proof: "live AX resource and actions", macosUseRPCs: []string{"GetElement", "GetElementActions"},
	},
	"focus_window": {
		source: "cua_window.go", handler: "cuaHandleFocusWindow", effect: "window mutation",
		proof: "owned focused-window delta", macosUseRPCs: []string{"FocusWindow"},
	},
	"move_window": {
		source: "cua_window.go", handler: "cuaHandleMoveWindow", effect: "window mutation",
		proof: "owned bounds delta", macosUseRPCs: []string{"MoveWindow"},
	},
	"resize_window": {
		source: "cua_window.go", handler: "cuaHandleResizeWindow", effect: "window mutation",
		proof: "owned bounds delta", macosUseRPCs: []string{"ResizeWindow"},
	},
	"list_windows": {
		source: "cua_window.go", handler: "cuaHandleListWindows", effect: "query",
		proof: "live window resources", macosUseRPCs: []string{"ListWindows"},
	},
	"clipboard": {
		source: "cua_clipboard.go", handler: "handleClipboard", effect: "clipboard query or mutation",
		proof:        "before and after clipboard contents",
		macosUseRPCs: []string{"GetClipboard", "WriteClipboard", "ClearClipboard"},
	},
	"run": {
		source: "cua_scripting.go", handler: "handleRun", effect: "script execution",
		proof:        "result and owned side effect",
		macosUseRPCs: []string{"ExecuteShellCommand", "ExecuteAppleScript", "ExecuteJavaScript"},
	},
	"get_display": {
		source: "cua_display.go", handler: "cuaHandleGetDisplay", effect: "query",
		proof:        "live display frames and cursor position",
		macosUseRPCs: []string{"CaptureCursorPosition"},
	},
	"create_macro": {
		source: "cua_macro.go", handler: "handleCreateMacro", effect: "macro lifecycle mutation",
		proof:        "stored macro resource",
		macosUseRPCs: []string{"CreateMacro"},
	},
	"get_macro": {
		source: "cua_macro.go", handler: "handleGetMacro", effect: "query",
		proof:        "stored macro resource",
		macosUseRPCs: []string{"GetMacro"},
	},
	"list_macros": {
		source: "cua_macro.go", handler: "handleListMacros", effect: "query",
		proof:        "stored macro resources and pagination",
		macosUseRPCs: []string{"ListMacros"},
	},
	"update_macro": {
		source: "cua_macro.go", handler: "handleUpdateMacro", effect: "macro lifecycle mutation",
		proof:        "stored macro resource delta",
		macosUseRPCs: []string{"UpdateMacro"},
	},
	"delete_macro": {
		source: "cua_macro.go", handler: "handleDeleteMacro", effect: "macro lifecycle mutation",
		proof:        "macro resource disappearance",
		macosUseRPCs: []string{"DeleteMacro"},
	},
	"execute_macro": {
		source: "cua_macro.go", handler: "handleExecuteMacro", effect: "macro execution",
		proof:        "owned long-running operation and runtime state",
		macosUseRPCs: []string{"ExecuteMacro"},
	},
}

type rpcFamilyContract struct {
	provider string
	effect   string
	proof    string
	methods  []string
}

var rpcFamilyContracts = []rpcFamilyContract{
	{
		provider: "ApplicationMethods.swift", effect: "application lifecycle", proof: "live process and resource state",
		methods: []string{
			"GetApplicationBundle", "ListApplicationBundles", "OpenApplication", "GetApplication", "ListApplications",
			"ActivateApplication", "CloseApplication",
		},
	},
	{
		provider: "InputMethods.swift", effect: "input lifecycle", proof: "injected operation then owned runtime state",
		methods: []string{"CreateInput", "GetInput", "ListInputs"},
	},
	{
		provider: "ElementMethods.swift", effect: "AX query, stream, or mutation", proof: "live AX state and stream lifecycle",
		methods: []string{
			"TraverseAccessibility", "WatchAccessibility", "FindElements", "FindRegionElements", "GetElement", "ListElements",
			"ClickElement", "WriteElementValue", "GetElementActions", "PerformElementAction", "WaitElement", "WaitElementState",
		},
	},
	{
		provider: "WindowMethods.swift", effect: "window query, mutation, or capture", proof: "owned window state delta or pixels",
		methods: []string{
			"GetWindow", "ListWindows", "GetWindowState", "FocusWindow", "MoveWindow", "ResizeWindow",
			"MinimizeWindow", "RestoreWindow", "CloseWindow", "CaptureWindowScreenshot",
		},
	},
	{
		provider: "ObservationMethods.swift", effect: "observation lifecycle or stream", proof: "events, cancellation, and cleanup",
		methods: []string{"CreateObservation", "GetObservation", "ListObservations", "CancelObservation", "StreamObservations"},
	},
	{
		provider: "SessionMethods.swift", effect: "session or transaction lifecycle", proof: "stored state and cleanup",
		methods: []string{
			"CreateSession", "GetSession", "ListSessions", "DeleteSession", "BeginTransaction", "CommitTransaction",
			"RollbackTransaction", "GetSessionSnapshot",
		},
	},
	{
		provider: "CaptureMethods.swift", effect: "capture", proof: "returned pixels and requested target metadata",
		methods: []string{"CaptureScreenshot", "CaptureElementScreenshot", "CaptureRegionScreenshot"},
	},
	{
		provider: "DisplayMethods.swift", effect: "display query", proof: "SDK and Core Graphics observed state",
		methods: []string{"ListDisplays", "GetDisplay", "CaptureCursorPosition"},
	},
	{
		provider: "ClipboardMethods.swift", effect: "clipboard query or mutation", proof: "before and after pasteboard contents",
		methods: []string{"GetClipboard", "WriteClipboard", "ClearClipboard", "GetClipboardHistory"},
	},
	{
		provider: "FileDialogMethods.swift", effect: "file dialog mutation", proof: "owned dialog selection and filesystem state",
		methods: []string{"AutomateOpenFileDialog", "AutomateSaveFileDialog"},
	},
	{
		provider: "MacroMethods.swift", effect: "macro lifecycle or execution", proof: "stored resource and owned runtime state",
		methods: []string{"CreateMacro", "GetMacro", "ListMacros", "UpdateMacro", "DeleteMacro", "ExecuteMacro"},
	},
	{
		provider: "ScriptingMethods.swift", effect: "script validation, query, or execution", proof: "result and owned side effect",
		methods: []string{"ExecuteAppleScript", "ExecuteJavaScript", "ExecuteShellCommand", "ValidateScript", "GetScriptingDictionaries"},
	},
}

type listedTool struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
}

type toolListResult struct {
	Tools []listedTool `json:"tools"`
}

type rpcContract struct {
	provider string
	effect   string
	proof    string
}
