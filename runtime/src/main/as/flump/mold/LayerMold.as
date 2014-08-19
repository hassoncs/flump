//
// Flump - Copyright 2013 Flump Authors

package flump.mold {

/** @private */
public class LayerMold
{
    public var name :String;
    public var keyframes :Vector.<KeyframeMold> = new <KeyframeMold>[];
    public var guide :Boolean = false;
    public var flipbook :Boolean;

    /** Text specific properties */
    public var fontFace :String = null, fontSize :Number = 0;

    public var defaultText:String = null;

    public var alignment:String = 'left';

    public var styleName:String = null;

    public static function fromJSON (o :Object) :LayerMold {
        const mold :LayerMold = new LayerMold();
        mold.name = require(o, "name");
        for each (var kf :Object in require(o, "keyframes")) {
            mold.keyframes.push(KeyframeMold.fromJSON(kf));
        }
        mold.guide = o.hasOwnProperty("guide");
        mold.flipbook = o.hasOwnProperty("flipbook");

        KeyframeMold.extractField(o, mold, "fontFace");
        KeyframeMold.extractField(o, mold, "fontSize");
        KeyframeMold.extractField(o, mold, "defaultText");
        KeyframeMold.extractField(o, mold, "alignment");
        KeyframeMold.extractField(o, mold, "styleName");

        return mold;
    }

    public function keyframeForFrame (frame :int) :KeyframeMold {
        var ii :int = 1;
        for (; ii < keyframes.length && keyframes[ii].index <= frame; ii++) {}
        return keyframes[ii - 1];
    }

    public function get frames () :int {
        if (keyframes.length == 0) return 0;
        const lastKf :KeyframeMold = keyframes[keyframes.length - 1];
        return lastKf.index + lastKf.duration;
    }

    public function toJSON (_:*) :Object {
        var json :Object = {
            name: name,
            keyframes: keyframes
        };
        if (guide) json.guide = guide;
        if (flipbook) json.flipbook = flipbook;
        if (fontFace != null) json.fontFace = fontFace;
        if (fontSize != 0) json.fontSize = KeyframeMold.round(fontSize);

        if (defaultText != null) json.defaultText = defaultText;
        if (styleName != null) json.styleName = styleName;
        json.alignment = alignment;

        return json;
    }

    public function toXML () :XML {
        var xml :XML = <layer name={name}/>;
        if (guide) xml.@guide = guide;
        if (flipbook) xml.@flipbook = flipbook;
        if (fontFace != null) xml.@fontFace = fontFace;
        if (fontSize != 0) xml.@fontSize = KeyframeMold.round(fontSize);
        for each (var kf :KeyframeMold in keyframes) xml.appendChild(kf.toXML());
        return xml;
    }
}
}
