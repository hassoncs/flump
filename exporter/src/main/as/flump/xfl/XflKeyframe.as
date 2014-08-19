//
// Flump - Copyright 2013 Flump Authors

package flump.xfl {

import aspire.util.MatrixUtil;
import aspire.util.XmlUtil;

import mx.utils.ObjectUtil;
import flash.geom.Matrix;

import flump.mold.KeyframeMold;

public class XflKeyframe
{
    public static const INDEX :String = "index";
    public static const DURATION :String = "duration";
    public static const NAME :String = "name";
    public static const EASE :String = "acceleration";
    public static const TWEEN_TYPE :String = "tweenType";
    public static const MOTION_TWEEN_ORIENT_TO_PATH :String = "motionTweenOrientToPath";
    public static const MOTION_TWEEN_ROTATE :String = "motionTweenRotate";
    public static const MOTION_TWEEN_ROTATE_TIMES :String = "motionTweenRotateTimes";
    public static const HAS_CUSTOM_EASE :String = "hasCustomEase";

    public static const MOTION_TWEEN_ROTATE_NONE :String = "none";
    public static const MOTION_TWEEN_ROTATE_CLOCKWISE :String = "clockwise";

    public static const TWEEN_TYPE_MOTION :String = "motion";

    public static const SYMBOL_INSTANCE :String = "DOMSymbolInstance";
    public static const TEXT_INSTANCE :String = "DOMDynamicText";

    use namespace xflns;

    public static function parse (lib :XflLibrary, baseLocation :String, xml :XML,
        flipbook :Boolean, guide :Boolean) :KeyframeMold {

        const kf :KeyframeMold = new KeyframeMold();
        kf.index = XmlUtil.getIntAttr(xml, INDEX);
        const location :String = baseLocation + ":" + (kf.index + 1);
        kf.duration = XmlUtil.getIntAttr(xml, DURATION, 1);
        kf.label = XmlUtil.getStringAttr(xml, NAME, null);
        kf.ease = XmlUtil.getNumberAttr(xml, EASE, 0) / 100;

        const tweenType :String = XmlUtil.getStringAttr(xml, TWEEN_TYPE, null);
        kf.tweened = (tweenType != null);
        if (tweenType != null && tweenType != TWEEN_TYPE_MOTION) {
            lib.addError(location, ParseError.WARN, "Unrecognized tweenType '" + tweenType + "'");
        }

        if (flipbook) {
            if (xml.elements.elements().length() == 0) {
                lib.addError(location, ParseError.CRIT, "Empty frames are not allowed in flipbooks");
            }
            return kf;
        }

        var instanceXml :XML = null;
        var isTextInstance :Boolean = false;
        for each (var frameChildXml :XML in xml.elements.elements()) {
            var localName:String = frameChildXml.name().localName;
            if (localName == SYMBOL_INSTANCE) {
                if (instanceXml != null)  {
                    lib.addError(location, ParseError.CRIT, "There can be only one symbol instance at " +
                        "a time in a keyframe.");
                } else instanceXml = frameChildXml;
            } else if (localName == TEXT_INSTANCE) {
                if (!guide) {
                    lib.addError(location, ParseError.CRIT, "Text instances must be on guide layers.");
                } else instanceXml = frameChildXml;
                isTextInstance = true;
            } else {
                if (!guide) {
                    lib.addError(location, ParseError.CRIT, "Non-supported instance found. Only movieClip instances or Sprites are allowed.");
                } else instanceXml = frameChildXml;
            }
        }

        if (instanceXml == null) return kf; // Purely labelled frame

        if (XmlUtil.getBooleanAttr(xml, MOTION_TWEEN_ORIENT_TO_PATH, false)) {
            lib.addError(location, ParseError.WARN, "Motion paths are not supported");
        }

        if (XmlUtil.getBooleanAttr(xml, HAS_CUSTOM_EASE, false)) {
            lib.addError(location, ParseError.WARN, "Custom easing is not supported");
        }

        // Fill this in with the library name for now. XflLibrary.finishLoading will swap in the
        // symbol or implicit symbol the library item corresponds to.
        try {
            var ref:String = XmlUtil.getStringAttr(instanceXml, XflInstance.LIBRARY_ITEM_NAME, '');
        } catch (myError:Error) {
        }
        try {
            kf.ref = ref || XmlUtil.getStringAttr(instanceXml, XflInstance.INSTANCE_NAME, '');
        } catch (myError:Error) {
        }

        if (isTextInstance) {
            var width:Number = XmlUtil.getNumberAttr(instanceXml, 'width', 0);
            var height:Number = XmlUtil.getNumberAttr(instanceXml, 'height', 0);
            kf.width = width;
            kf.height = height;
        }

        kf.visible = XmlUtil.getBooleanAttr(instanceXml, XflInstance.IS_VISIBLE, true);

        // Read the matrix transform
        var matrix :Matrix;
        const matrixXml :XML = XflInstance.getMatrixXml(instanceXml);
        if (matrixXml == null) {
            matrix = new Matrix();
        } else {
            function m (name :String, def :Number) :Number {
                return XmlUtil.getNumberAttr(matrixXml, name, def);
            }
            matrix = new Matrix(m("a", 1), m("b", 0), m("c", 0), m("d", 1), m("tx", 0), m("ty", 0));

            kf.scaleX = MatrixUtil.scaleX(matrix);
            kf.scaleY = MatrixUtil.scaleY(matrix);
            kf.skewX = MatrixUtil.skewX(matrix);
            kf.skewY = MatrixUtil.skewY(matrix);
        }

        // Read the pivot point
        var pivotXml :XML = XflInstance.getTransformationPointXml(instanceXml);
        if (pivotXml != null) {
            kf.pivotX = XmlUtil.getNumberAttr(pivotXml, "x", 0);
            kf.pivotY = XmlUtil.getNumberAttr(pivotXml, "y", 0);

            // Translate to the pivot point
            const orig :Matrix = matrix.clone();
            matrix.identity();
            matrix.translate(kf.pivotX, kf.pivotY);
            matrix.concat(orig);
        }

        // Now that the matrix and pivot point have been read, apply translation
        kf.x = matrix.tx;
        kf.y = matrix.ty;

        // Read the alpha
        const colorXml :XML = XflInstance.getColorXml(instanceXml);
        if (colorXml != null) {
            kf.alpha = XmlUtil.getNumberAttr(colorXml, XflInstance.ALPHA, 1);
        }
        return kf;
    }
}
}
