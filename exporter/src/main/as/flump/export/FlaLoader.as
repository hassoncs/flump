//
// Flump - Copyright 2013 Flump Authors

package flump.export {

import aspire.util.F;
import aspire.util.Log;

import deng.fzip.FZip;
import deng.fzip.FZipFile;

import flash.filesystem.File;
import flash.utils.ByteArray;

import flump.executor.Executor;
import flump.executor.Future;
import flump.executor.FutureTask;
import flump.xfl.ParseError;
import flump.xfl.XflLibrary;

public class FlaLoader
{
    public function load (name :String, file :File) :Future {
        log.info("Loading fla", "path", file.nativePath, "name", name);

        const future :FutureTask = new FutureTask();
        _library = new XflLibrary(name);
        _loader.terminated.connect(function (..._) :void {
            _library.finishLoading();
            future.succeed(_library);
        });

        var loadSWF :Future = _library.loadSWF(Files.replaceExtension(file, "swf"));
        loadSWF.succeeded.connect(function () :void {
            log.info("Loaded, parsing its library now...");
            // Since listLibrary shuts down the executor, wait for the swf to load first
            listLibrary(file);
        });
        loadSWF.failed.connect(function () :void {
            log.info("Damn, the fla failed to load:", file.nativePath, "with name", name);
            F.adapt(_loader.shutdown);
        });

        return future;
    }

    protected function listLibrary (file :File) :void {
        const loadZip :Future = Files.load(file, _loader);
        loadZip.succeeded.connect(function (data :ByteArray) :void {
            const zip :FZip = new FZip();
            zip.loadBytes(data);

            log.info("Fla zip loaded, loading domFile and symbols...");
            const domFile :FZipFile = zip.getFileByName("DOMDocument.xml");
            const symbolPaths :Vector.<String> = _library.parseDocumentFile(
                domFile.content, domFile.filename);
            for each (var path :String in symbolPaths) {
                var symbolFile :FZipFile = zip.getFileByName(path);
                var layoutOnlyLibrary :Boolean = (path.toLowerCase().indexOf('layout') > -1);
                _library.parseLibraryFile(symbolFile.content, path, layoutOnlyLibrary);
            }
            _loader.shutdown();
        });
        loadZip.failed.connect(function (error :Error) :void {
            log.error("Failed to load the zip from the fla", error.message);
            _library.addTopLevelError(ParseError.CRIT, error.message, error);
            _loader.shutdown();
        });
    }

    protected const _loader :Executor = new Executor();

    protected var _library :XflLibrary;

    private static const log :Log = Log.getLog(FlaLoader);
}
}
