//
// Flump - Copyright 2013 Flump Authors

package flump.export {

import aspire.util.F;
import aspire.util.Log;
import aspire.util.StringUtil;

import flash.desktop.NativeProcessStartupInfo;
import flash.desktop.NativeApplication;
import flash.desktop.NativeProcess;
import flash.display.NativeMenu;
import flash.display.NativeMenuItem;
import flash.display.Stage;
import flash.display.StageQuality;
import flash.events.Event;
import flash.events.MouseEvent;
import flash.events.ProgressEvent;
import flash.filesystem.File;
import flash.utils.IDataOutput;

import flump.executor.Executor;
import flump.executor.Future;
import flump.xfl.ParseError;
import flump.xfl.XflLibrary;

import mx.events.FlexEvent;
import mx.events.PropertyChangeEvent;
import mx.managers.PopUpManager;

import spark.components.DataGrid;
import spark.components.Window;
import spark.events.GridSelectionEvent;

import com.adobe.air.filesystem.FileMonitor;
import com.adobe.air.filesystem.events.FileMonitorEvent;

public class ProjectController
{
    public static const NA :NativeApplication = NativeApplication.nativeApplication;

    public function ProjectController (configFile :File = null) {
        _win = new ProjectWindow();
        _win.open();
        _errorsGrid = _win.errors;
        _flashDocsGrid = _win.libraries;

        _confFile = configFile;
        if (_confFile != null) {
            try {
                _conf = ProjectConf.fromJSON(JSONFormat.readJSON(_confFile));
                var dir :String = _confFile.parent.resolvePath(_conf.importDir).nativePath;
                var dirFile :File = new File(dir);
                if (!dirFile.exists || !dirFile.isDirectory) {
                    _errorsGrid.dataProvider.addItem(new ParseError(_confFile.nativePath,
                        ParseError.CRIT, "Import directory doesn't exist ('" + dir + "')"));
                    _confFile = null;
                    _conf = null;
                } else {
                    setImportDirectory(dirFile);
                }
            } catch (e :Error) {
                log.warning("Unable to parse conf", e);
                _errorsGrid.dataProvider.addItem(new ParseError(_confFile.nativePath,
                    ParseError.CRIT, "Unable to read configuration"));
                _confFile = null;
                _conf = null;
            }
        }

        var curSelection :DocStatus = null;
        _flashDocsGrid.addEventListener(GridSelectionEvent.SELECTION_CHANGE, function (..._) :void {
            log.info("Changed", "selected", _flashDocsGrid.selectedIndices);
            onSelectedItemChanged();

            if (curSelection != null) {
                curSelection.removeEventListener(PropertyChangeEvent.PROPERTY_CHANGE,
                    onSelectedItemChanged);
            }
            var newSelection :DocStatus = _flashDocsGrid.selectedItem as DocStatus;
            if (newSelection != null) {
                newSelection.addEventListener(PropertyChangeEvent.PROPERTY_CHANGE,
                    onSelectedItemChanged);
            }
            curSelection = newSelection;
        });

        // Reload
        _win.reload.addEventListener(MouseEvent.CLICK, F.bind(reloadNow));

        // Export
        _win.export.addEventListener(MouseEvent.CLICK, function (..._) :void {
            for each (var status :DocStatus in _flashDocsGrid.selectedItems) {
                exportFlashDocument(status);
            }
        });

        // Preview
        _win.preview.addEventListener(MouseEvent.CLICK, function (..._) :void {
            FlumpApp.app.showPreviewWindow(_conf, _flashDocsGrid.selectedItem.lib);
        });

        // Export All, Modified
        _win.exportAll.addEventListener(MouseEvent.CLICK, F.bind(exportAll, false));
        _win.exportModified.addEventListener(MouseEvent.CLICK, F.bind(exportAll, true));

        // Import/Export directories
        _importChooser = new DirChooser(null, _win.importRoot, _win.browseImport);
        _importChooser.changed.connect(setImportDirectory);
        _exportChooser = new DirChooser(null, _win.exportRoot, _win.browseExport);
        _exportChooser.changed.connect(F.bind(reloadNow));

        _importChooser.changed.connect(F.bind(setProjectDirty, true));
        _exportChooser.changed.connect(F.bind(setProjectDirty, true));

        // Edit Formats
        var editFormatsController :EditFormatsController = null;
        _win.editFormats.addEventListener(MouseEvent.CLICK, function (..._) :void {
            if (editFormatsController == null || editFormatsController.closed) {
                editFormatsController = new EditFormatsController(_conf);
                editFormatsController.formatsChanged.connect(updateUiFromConf);
                editFormatsController.formatsChanged.connect(F.bind(setProjectDirty, true));
            } else {
                editFormatsController.show();
            }
        });

        _win.addEventListener(Event.CLOSING, function (e :Event) :void {
            if (_projectDirty) {
                e.preventDefault();
                promptToSaveChanges();
            }
        });

        updateUiFromConf();
        updateWindowTitle();

        setupMenus();
    }

    public function get projectDirty () :Boolean {
        return _projectDirty;
    }

    public function get projectName () :String {
        return (_confFile != null ? _confFile.name.replace(/\.flump$/i, "") : "Untitled Project");
    }

    public function save (onSuccess :Function = null) :void {
        if (_confFile == null) {
            saveAs(onSuccess);
        } else {
            saveConf(onSuccess);
        }
    }

    public function saveAs (onSuccess :Function = null) :void {
        var file :File = new File();
        file.addEventListener(Event.SELECT, function (..._) :void {
            // Ensure the filename ends with .flump
            if (!StringUtil.endsWith(file.name.toLowerCase(), ".flump")) {
                file = file.parent.resolvePath(file.name + ".flump");
            }

            _confFile = file;
            saveConf(onSuccess);
        });
        file.browseForSave("Save Flump Configuration");
    }

    public function get configFile () :File {
        return _confFile;
    }

    public function get win () :Window {
        return _win;
    }

    public function exportAll (modifiedOnly :Boolean) :void {
        for each (var status :DocStatus in _flashDocsGrid.dataProvider.toArray()) {
            if (status.isValid && (!modifiedOnly || status.isModified)) {
                exportFlashDocument(status);
            } else if (modifiedOnly && !status.isModified) {
                trace("Skipping '" + status.path + "'-- it hasn't changed.");
            }
        }
    }

    protected function promptToSaveChanges () :void {
        var unsavedWindow :UnsavedChangesWindow = new UnsavedChangesWindow();
        unsavedWindow.x = (_win.width - unsavedWindow.width) * 0.5;
        unsavedWindow.y = (_win.height - unsavedWindow.height) * 0.5;
        PopUpManager.addPopUp(unsavedWindow, _win, true);

        unsavedWindow.closeButton.visible = false;
        unsavedWindow.prompt.text = "Save changes to '" + projectName + "'?";

        unsavedWindow.cancel.addEventListener(MouseEvent.CLICK, function (..._) :void {
            PopUpManager.removePopUp(unsavedWindow);
        });

        unsavedWindow.dontSave.addEventListener(MouseEvent.CLICK, function (..._) :void {
            PopUpManager.removePopUp(unsavedWindow);
            _projectDirty = false;
            _win.close();
        });

        unsavedWindow.save.addEventListener(MouseEvent.CLICK, function (..._) :void {
            PopUpManager.removePopUp(unsavedWindow);
            save(F.bind(_win.close));
        });
    }

    protected function setupMenus () :void {
        if (NativeApplication.supportsMenu) {
            // If we're on a Mac, the menus will be set up at the application level.
            return;
        }

        _win.nativeWindow.menu = new NativeMenu();

        var fileMenuItem  :NativeMenuItem =
            _win.nativeWindow.menu.addSubmenu(new NativeMenu(), "File");

        // Add save and save as by index to work with the existing items on Mac
        // Mac menus have an existing "Close" item, so everything we add should go ahead of that
        var newMenuItem :NativeMenuItem = fileMenuItem.submenu.addItemAt(new NativeMenuItem("New Project"), 0);
        newMenuItem.keyEquivalent = "n";
        newMenuItem.addEventListener(Event.SELECT, function (..._) :void {
            FlumpApp.app.newProject();
        });

        var openMenuItem :NativeMenuItem =
            fileMenuItem.submenu.addItemAt(new NativeMenuItem("Open Project..."), 1);
        openMenuItem.keyEquivalent = "o";
        openMenuItem.addEventListener(Event.SELECT, function (..._) :void {
            FlumpApp.app.showOpenProjectDialog();
        });
        fileMenuItem.submenu.addItemAt(new NativeMenuItem("Sep", /*separator=*/true), 2);

        const saveMenuItem :NativeMenuItem =
            fileMenuItem.submenu.addItemAt(new NativeMenuItem("Save Project"), 3);
        saveMenuItem.keyEquivalent = "s";
        saveMenuItem.addEventListener(Event.SELECT, F.bind(save));

        const saveAsMenuItem :NativeMenuItem =
            fileMenuItem.submenu.addItemAt(new NativeMenuItem("Save Project As..."), 4);
        saveAsMenuItem.keyEquivalent = "S";
        saveAsMenuItem.addEventListener(Event.SELECT, F.bind(saveAs));
    }

    protected function updateWindowTitle () :void {
        var name :String = this.projectName;
        if (_projectDirty) name += "*";
        _win.title = name;
    }

    protected function saveConf (onSuccess :Function) :void {
        Files.write(_confFile, function (out :IDataOutput) :void {
            // Set directories relative to where this file is being saved. Fall back to absolute
            // paths if relative paths aren't possible.
            if (_importChooser.dir != null) {
                _conf.importDir = _confFile.parent.getRelativePath(_importChooser.dir, /*useDotDot=*/true);
                if (_conf.importDir == null) _conf.importDir = _importChooser.dir.nativePath;
            }

            if (_exportChooser.dir != null) {
                _conf.exportDir = _confFile.parent.getRelativePath(_exportChooser.dir, /*useDotDot=*/true);
                if (_conf.exportDir == null) _conf.exportDir = _exportChooser.dir.nativePath;
            }

            out.writeUTFBytes(JSON.stringify(_conf, null, /*space=*/2));

            setProjectDirty(false);
            updateWindowTitle();

            if (onSuccess != null) {
                onSuccess();
            }
        });
    }

    public function reloadNow () :void {
        setImportDirectory(_importChooser.dir);
        onSelectedItemChanged();
    }

    protected function updateUiFromConf (..._) :void {
        if (_confFile != null) {
            _importChooser.dir = (_conf.importDir != null) ? _confFile.parent.resolvePath(_conf.importDir) : null;
            _exportChooser.dir = (_conf.exportDir != null) ? _confFile.parent.resolvePath(_conf.exportDir) : null;
        } else {
            _importChooser.dir = null;
            _exportChooser.dir = null;
        }

        var formatNames :Array = [];
        if (_conf != null) {
            for each (var export :ExportConf in _conf.exports) {
                formatNames.push(export.description);
            }
        }
        _win.formatOverview.text = formatNames.join(", ");

        updateWindowTitle();
    }

    protected function onSelectedItemChanged (..._) :void {
        _win.export.enabled = _exportChooser.dir != null && _flashDocsGrid.selectionLength > 0 &&
            _flashDocsGrid.selectedItems.some(function (status :DocStatus, ..._) :Boolean {
                return status.isValid;
            });

        var status :DocStatus = _flashDocsGrid.selectedItem as DocStatus;
        _win.preview.enabled = status != null && status.isValid;

        _win.selectedItem.text = (status == null ? "" : status.path);
    }

    protected function createPublisher () :Publisher {
        if (_exportChooser.dir == null || _conf.exports.length == 0) return null;
        return new Publisher(_exportChooser.dir, _conf);
    }

    protected function setImportDirectory (dir :File) :void {
        _importDirectory = dir;
        _flashDocsGrid.dataProvider.removeAll();
        _errorsGrid.dataProvider.removeAll();
        if (dir == null) {
            return;

        }
        if (_docFinder != null) {
            _docFinder.shutdownNow();
        }
        _docFinder = new Executor();
        findFlashDocuments(dir, _docFinder, true);
        _win.reload.enabled = true;
    }

    protected function findFlashDocuments (base :File, exec :Executor, ignoreXflAtBase :Boolean = false) :void {
        Files.list(base, exec).succeeded.connect(function (files :Array) :void {
            if (exec.isShutdown) return;

            for each (var file :File in files) {
                if (Files.hasExtension(file, "xfl")) {
                    if (ignoreXflAtBase) {
                        _errorsGrid.dataProvider.addItem(new ParseError(base.nativePath,
                            ParseError.CRIT, "The import directory can't be an XFL directory, did you mean " +
                            base.parent.nativePath + "?"));
                    } else addFlashDocument(file);
                    return;
                }
            }
            for each (file in files) {
                if (StringUtil.startsWith(file.name, ".", "RECOVER_")) {
                    continue; // Ignore hidden VCS directories, and recovered backups created by Flash
                }
                if (file.isDirectory) findFlashDocuments(file, exec);
                else addFlashDocument(file);
            }
        });
    }

    protected function exportFlashDocument (status :DocStatus) :void {
        const stage :Stage = _win.stage;
        const prevQuality :String = stage.quality;

        stage.quality = StageQuality.BEST;

        try {
            if (_exportChooser.dir == null) {
                throw new Error("No export directory specified.");
            }
            if (_conf.exports.length == 0) {
                throw new Error("No export formats specified.");
            }
            createPublisher().publish(status.lib);
        } catch (e :Error) {
            ErrorWindowMgr.showErrorPopup("Publishing Failed", e.message, _win);
        }

        stage.quality = prevQuality;
        status.updateModified(Ternary.FALSE);
    }

    protected function addFlashDocument (file :File) :void {
        var importPathLen :int = _importDirectory.nativePath.length + 1;
        var name :String = file.nativePath.substring(importPathLen).replace(
            new RegExp("\\" + File.separator, "g"), "/");

        var loader :FlaLoader;
        var load :Future;
        switch (Files.getExtension(file)) {
        case "xfl":
            name = name.substr(0, name.lastIndexOf("/"));
            load = new XflLoader().load(name, file.parent);
            break;
        case "fla":
            name = name.substr(0, name.lastIndexOf("."));
            loader = new FlaLoader();
            load = loader.load(name, file);
            break;
        default:
            // Unsupported file type, ignore
            return;
        }

        const status :DocStatus = new DocStatus(name, Ternary.UNKNOWN, Ternary.UNKNOWN, null, file.nativePath);
        _flashDocsGrid.dataProvider.addItem(status);
        _docsToSave++;

        status.addEventListener(FileMonitorEvent.CHANGE, function(e:FileMonitorEvent):void
        {
            trace("File was changed: " + e.file.nativePath);
            var load:Future = new FlaLoader().load(name, file);
            load.succeeded.connect(function(lib :XflLibrary) :void {
                status.lib = lib;
                log.info("Running auto export-");
                if (_docFinder != null) {
                    _docFinder.shutdownNow();
                }

                exportFlashDocument(status);
                log.info("Export done, about to run external command.");

                tryCallExternalCommand();
                _win.nativeWindow.minimize();
            });
        });


        load.succeeded.connect(function(lib :XflLibrary) :void {
            updateLoadedLibrary(lib, status);
        });

        load.failed.connect(function (error :Error) :void {
            trace("Failed to load " + file.nativePath + ": " + error);
            status.updateValid(Ternary.FALSE);
            throw error;
        });
    }

    public function updateLoadedLibrary(lib :XflLibrary, status :DocStatus) :void {
        var pub :Publisher = createPublisher();
        status.lib = lib;
        status.updateModified(Ternary.of(pub == null || pub.modified(lib)));
        for each (var err :ParseError in lib.getErrors()) _errorsGrid.dataProvider.addItem(err);
        status.updateValid(Ternary.of(lib.valid));

        _docsToSave--;
        if (_docsToSave <= 0) {
            trace('Cloverfield auto export triggered.');
            _win.nativeWindow.minimize();
            exportAll(true);
        }
    }

    public function setProjectDirty (val :Boolean) :void {
        if (_projectDirty != val) {
            _projectDirty = val;
            updateWindowTitle();
        }
    }

    public function tryCallExternalCommand() :void {
        try {
            callExternalCommand();
        } catch (e:Error) {
            log.error(e.name, e.message, e.getStackTrace());
        }
    }

    public function callExternalCommand() :void {
        log.info("_externalAppCallbackWorkingDir", _externalAppCallbackWorkingDir);
        log.info("_externalAppCallbackCmd", _externalAppCallbackCmd);
        log.info("_externalAppCallbackArgs", _externalAppCallbackArgs);
        if (!_externalAppCallbackCmd || !_externalAppCallbackWorkingDir) return;

        var nativeProcessStartupInfo:NativeProcessStartupInfo = new NativeProcessStartupInfo();
        var file:File = new File(_externalAppCallbackCmd);
        var processArgs:Vector.<String> = new Vector.<String>();
        var process:NativeProcess = new NativeProcess();

        var nativeCmd:String = 'cd ' + _externalAppCallbackWorkingDir + ';' + _externalAppCallbackCmd + ' ' + _externalAppCallbackArgs;
        log.info("Flump executing native command: '" + nativeCmd + "'");

        processArgs.push(_externalAppCallbackArgs);
        nativeProcessStartupInfo.executable = file;
        nativeProcessStartupInfo.workingDirectory = new File(_externalAppCallbackWorkingDir);
        nativeProcessStartupInfo.arguments = processArgs;

        process.addEventListener(ProgressEvent.STANDARD_OUTPUT_DATA, function onOutputData(event:ProgressEvent) :void
        {
            var stdOut:flash.utils.IDataInput = process.standardOutput;
            var data:String = stdOut.readUTFBytes(process.standardOutput.bytesAvailable);
            log.info(data);
        });
        process.start(nativeProcessStartupInfo);
    }


    public var _externalAppCallbackCmd :String;
    public var _externalAppCallbackArgs :String;
    public var _externalAppCallbackWorkingDir :String;

    protected var _importDirectory :File;

    protected var _docFinder :Executor;
    protected var _win :ProjectWindow;
    protected var _flashDocsGrid :DataGrid;
    protected var _errorsGrid :DataGrid;
    protected var _exportChooser :DirChooser;
    protected var _importChooser :DirChooser;
    protected var _conf :ProjectConf = new ProjectConf();
    protected var _confFile :File;

    protected var _docsToSave :Number = 0;
    protected var _projectDirty :Boolean; // true if project has unsaved changes


    private static const log :Log = Log.getLog(ProjectController);
}
}

import flash.utils.Timer;
import flash.events.TimerEvent;
import flash.events.Event;
import flash.events.EventDispatcher;

import flump.export.Ternary;
import flump.xfl.XflLibrary;

import flash.filesystem.File;

import mx.core.IPropertyChangeNotifier;
import mx.events.PropertyChangeEvent;

import com.adobe.air.filesystem.FileMonitor;
import com.adobe.air.filesystem.events.FileMonitorEvent;

class DocStatus extends EventDispatcher implements IPropertyChangeNotifier {
    public var path :String;
    public var modified :String;
    public var valid :String = PENDING;
    public var lib :XflLibrary;
    public var monitor:FileMonitor;
    private var lastChangedTimer:Timer;
    private var waitForSaveTimer:Timer;

    public function DocStatus (path :String, modified :Ternary, valid :Ternary, lib :XflLibrary, nativePath :String) {
        this.lib = lib;
        this.path = path;
        _uid = path;

        updateModified(modified);
        updateValid(valid);
        setupFileMonitoring(nativePath);
    }

    private function setupFileMonitoring(path:String):void
    {
        var swfPath:String = path.replace('.fla', '.swf');
        var swfFile:File = new File(swfPath);
        monitor = new FileMonitor(swfFile, 5000);
        monitor.watch();
        var doc:DocStatus = this;

        monitor.addEventListener(FileMonitorEvent.CHANGE, function(e:FileMonitorEvent):void
        {
            if (lastChangedTimer && lastChangedTimer.running) return;
            lastChangedTimer = new Timer(MONITOR_DEBOUNCE_DELAY_MS, 0 /* Repeat */);
//            lastChangedTimer.start();

            trace('Saw file change, waiting for save to complete before trying to read the file.');
            waitForSaveTimer = new Timer(1500, 0 /* Repeat */);
            waitForSaveTimer.addEventListener(TimerEvent.TIMER, function(ev:TimerEvent) :void {
                waitForSaveTimer.stop();
                trace('Dispatching change event...');
                doc.dispatchEvent(e);
            });
            waitForSaveTimer.start();
        });


        trace("watching file: " + swfFile.nativePath);
    }

    public function updateValid (newValid :Ternary) :void {
        changeField("valid", function (..._) :void {
            if (newValid == Ternary.TRUE) valid = YES;
            else if (newValid == Ternary.FALSE) valid = ERROR;
            else valid = PENDING;
        });
    }

    public function get isValid () :Boolean { return valid == YES; }

    public function get isModified () :Boolean { return modified == YES; }

    public function updateModified (newModified :Ternary) :void {
        changeField("modified", function (..._) :void {
            if (newModified == Ternary.TRUE) modified = YES;
            else if (newModified == Ternary.FALSE) modified = " ";
            else modified = PENDING;
        });
    }

    protected function changeField(fieldName :String, modifier :Function) :void {
        const oldValue :Object = this[fieldName];
        modifier();
        const newValue :Object = this[fieldName];
        dispatchEvent(PropertyChangeEvent.createUpdateEvent(this, fieldName, oldValue, newValue));
    }

    public function get uid () :String { return _uid; }
    public function set uid (uid :String) :void { _uid = uid; }

    protected var _uid :String;

    protected static const PENDING :String = "...";
    protected static const ERROR :String = "ERROR";
    protected static const YES :String = "Yes";
    protected static const MONITOR_DEBOUNCE_DELAY_MS :Number = 5000;
}
