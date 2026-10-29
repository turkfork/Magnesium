package turkfork.magnesium.client.renderer.device;

import org.lwjgl.opengl.GL11;
import org.lwjgl.opengl.GL12;
import org.lwjgl.opengl.GL13;
import org.lwjgl.opengl.GL14;
import org.lwjgl.opengl.GL20;
import org.lwjgl.opengl.GL30;
import org.lwjgl.opengl.GL31;
import turkfork.magnesium.client.renderer.MetalBridge;

/**
 * Composites a Metal-rendered terrain frame into the bound OpenGL framebuffer.
 *
 * <p>The Metal color (premultiplied RGBA8) and depth (R32F) readbacks are
 * uploaded to GL textures and drawn as a fullscreen triangle whose fragment
 * shader writes {@code gl_FragDepth}. Metal's depth uses the same [0, 1] range
 * and projection remap as OpenGL's default depth range, so the existing depth
 * buffer (entities, sky) sorts against the terrain correctly.
 *
 * <p>Everything here uses raw GL and restores exactly the state it read on
 * entry. It deliberately avoids {@code GlStateManager}: Sodium and Iris change
 * the active texture unit and bindings with raw calls, so Minecraft's cached
 * values can be stale, and a cached "bind unit 0" would then be skipped or hit
 * the wrong unit.
 */
final class MagnesiumGlComposite {

    private static final String VERTEX_SHADER = """
            #version 330 core
            out vec2 v_Uv;
            void main() {
                vec2 pos = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
                v_Uv = pos;
                gl_Position = vec4(pos * 2.0 - 1.0, 0.0, 1.0);
            }
            """;

    private static final String FRAGMENT_SHADER = """
            #version 330 core
            uniform sampler2D u_Color;
            uniform sampler2D u_Depth;
            in vec2 v_Uv;
            out vec4 fragColor;
            void main() {
                // Metal readbacks are top-row-first; GL textures are bottom-row-first.
                vec2 uv = vec2(v_Uv.x, 1.0 - v_Uv.y);
                vec4 color = texture(u_Color, uv);
                float depth = texture(u_Depth, uv).r;
                if (color.a <= 0.0 && depth >= 1.0) {
                    discard;
                }
                fragColor = color;
                gl_FragDepth = depth;
            }
            """;

    private static int program = 0;
    private static int vao = 0;
    private static int colorTexture = 0;
    private static int depthTexture = 0;
    private static int textureWidth = 0;
    private static int textureHeight = 0;
    private static boolean failed = false;

    private static final String ZERO_COPY_FRAGMENT_SHADER = """
            #version 330 core
            uniform sampler2DRect u_Color;
            uniform sampler2DRect u_Depth;
            in vec2 v_Uv;
            out vec4 fragColor;
            void main() {
                // IOSurface rows are top-first; v_Uv is bottom-first.
                ivec2 size = textureSize(u_Color);
                ivec2 p = clamp(ivec2(vec2(v_Uv.x, 1.0 - v_Uv.y) * vec2(size)),
                        ivec2(0), size - ivec2(1));
                vec4 color = texelFetch(u_Color, p);
                vec3 b = floor(texelFetch(u_Depth, p).rgb * 255.0 + 0.5);
                float depth = (b.r * 65536.0 + b.g * 256.0 + b.b) / 16777215.0;
                if (color.a <= 0.0 && depth >= 1.0) {
                    discard;
                }
                fragColor = color;
                gl_FragDepth = depth;
            }
            """;

    private static int zeroProgram = 0;
    private static int zeroColorTexture = 0;
    private static int zeroDepthTexture = 0;
    private static boolean zeroCopyDisabled = Boolean.getBoolean("magnesium.nozerocopy");

    private MagnesiumGlComposite() {
    }

    static boolean zeroCopyAllowed() {
        return !zeroCopyDisabled;
    }

    static void disableZeroCopy() {
        zeroCopyDisabled = true;
        System.err.println("[Magnesium] Zero-copy composite unavailable; falling back to readback.");
    }

    /**
     * Composites the IOSurface-backed Metal frame. The surfaces are rebound
     * every frame, as CGL requires after the contents changed.
     *
     * @return false if the surfaces could not be bound or the shader failed
     */
    static boolean compositeZeroCopy() {
        if (failed) {
            return true;
        }
        if (program == 0 && !init()) {
            failed = true;
            return true;
        }
        if (zeroProgram == 0 && !initZeroCopy()) {
            return false;
        }

        int prevProgram = GL11.glGetInteger(GL20.GL_CURRENT_PROGRAM);
        int prevVao = GL11.glGetInteger(GL30.GL_VERTEX_ARRAY_BINDING);
        int prevActive = GL11.glGetInteger(GL13.GL_ACTIVE_TEXTURE);
        GL13.glActiveTexture(GL13.GL_TEXTURE0);
        int prevTex0 = GL11.glGetInteger(GL31.GL_TEXTURE_BINDING_RECTANGLE);
        GL13.glActiveTexture(GL13.GL_TEXTURE1);
        int prevTex1 = GL11.glGetInteger(GL31.GL_TEXTURE_BINDING_RECTANGLE);
        boolean prevBlend = GL11.glIsEnabled(GL11.GL_BLEND);
        int prevSrcRgb = GL11.glGetInteger(GL14.GL_BLEND_SRC_RGB);
        int prevDstRgb = GL11.glGetInteger(GL14.GL_BLEND_DST_RGB);
        int prevSrcA = GL11.glGetInteger(GL14.GL_BLEND_SRC_ALPHA);
        int prevDstA = GL11.glGetInteger(GL14.GL_BLEND_DST_ALPHA);
        boolean prevDepthTest = GL11.glIsEnabled(GL11.GL_DEPTH_TEST);
        int prevDepthFunc = GL11.glGetInteger(GL11.GL_DEPTH_FUNC);
        boolean prevDepthMask = GL11.glGetBoolean(GL11.GL_DEPTH_WRITEMASK);
        boolean prevCull = GL11.glIsEnabled(GL11.GL_CULL_FACE);

        boolean bound = false;
        try {
            GL13.glActiveTexture(GL13.GL_TEXTURE0);
            GL11.glBindTexture(GL31.GL_TEXTURE_RECTANGLE, zeroColorTexture);
            bound = MetalBridge.bindFrameSurface(0);
            rectangleParameters();
            GL13.glActiveTexture(GL13.GL_TEXTURE1);
            GL11.glBindTexture(GL31.GL_TEXTURE_RECTANGLE, zeroDepthTexture);
            bound &= MetalBridge.bindFrameSurface(1);
            rectangleParameters();
            if (!bound) {
                return false;
            }

            GL11.glDisable(GL11.GL_CULL_FACE);
            GL11.glEnable(GL11.GL_DEPTH_TEST);
            GL11.glDepthFunc(GL11.GL_LEQUAL);
            GL11.glDepthMask(true);
            GL11.glEnable(GL11.GL_BLEND);
            GL14.glBlendFuncSeparate(
                    GL11.GL_ONE, GL11.GL_ONE_MINUS_SRC_ALPHA,
                    GL11.GL_ONE, GL11.GL_ONE_MINUS_SRC_ALPHA);

            GL20.glUseProgram(zeroProgram);
            GL30.glBindVertexArray(vao);
            GL11.glDrawArrays(GL11.GL_TRIANGLES, 0, 3);
            return true;
        } finally {
            GL30.glBindVertexArray(prevVao);
            GL20.glUseProgram(prevProgram);
            GL13.glActiveTexture(GL13.GL_TEXTURE1);
            GL11.glBindTexture(GL31.GL_TEXTURE_RECTANGLE, prevTex1);
            GL13.glActiveTexture(GL13.GL_TEXTURE0);
            GL11.glBindTexture(GL31.GL_TEXTURE_RECTANGLE, prevTex0);
            GL13.glActiveTexture(prevActive);
            GL14.glBlendFuncSeparate(prevSrcRgb, prevDstRgb, prevSrcA, prevDstA);
            setEnabled(GL11.GL_BLEND, prevBlend);
            GL11.glDepthFunc(prevDepthFunc);
            GL11.glDepthMask(prevDepthMask);
            setEnabled(GL11.GL_DEPTH_TEST, prevDepthTest);
            setEnabled(GL11.GL_CULL_FACE, prevCull);
        }
    }

    private static void rectangleParameters() {
        GL11.glTexParameteri(GL31.GL_TEXTURE_RECTANGLE, GL11.GL_TEXTURE_MIN_FILTER, GL11.GL_NEAREST);
        GL11.glTexParameteri(GL31.GL_TEXTURE_RECTANGLE, GL11.GL_TEXTURE_MAG_FILTER, GL11.GL_NEAREST);
        GL11.glTexParameteri(GL31.GL_TEXTURE_RECTANGLE, GL11.GL_TEXTURE_WRAP_S, GL13.GL_CLAMP_TO_EDGE);
        GL11.glTexParameteri(GL31.GL_TEXTURE_RECTANGLE, GL11.GL_TEXTURE_WRAP_T, GL13.GL_CLAMP_TO_EDGE);
    }

    private static boolean initZeroCopy() {
        int vs = compile(GL20.GL_VERTEX_SHADER, VERTEX_SHADER);
        int fs = compile(GL20.GL_FRAGMENT_SHADER, ZERO_COPY_FRAGMENT_SHADER);
        if (vs == 0 || fs == 0) {
            return false;
        }
        int linked = GL20.glCreateProgram();
        GL20.glAttachShader(linked, vs);
        GL20.glAttachShader(linked, fs);
        GL20.glLinkProgram(linked);
        GL20.glDeleteShader(vs);
        GL20.glDeleteShader(fs);
        if (GL20.glGetProgrami(linked, GL20.GL_LINK_STATUS) == GL11.GL_FALSE) {
            System.err.println("[Magnesium] Zero-copy composite link failed: "
                    + GL20.glGetProgramInfoLog(linked));
            GL20.glDeleteProgram(linked);
            return false;
        }
        int prevProgram = GL11.glGetInteger(GL20.GL_CURRENT_PROGRAM);
        GL20.glUseProgram(linked);
        GL20.glUniform1i(GL20.glGetUniformLocation(linked, "u_Color"), 0);
        GL20.glUniform1i(GL20.glGetUniformLocation(linked, "u_Depth"), 1);
        GL20.glUseProgram(prevProgram);
        zeroProgram = linked;
        zeroColorTexture = GL11.glGenTextures();
        zeroDepthTexture = GL11.glGenTextures();
        System.out.println("[Magnesium] Zero-copy (IOSurface) composite ready.");
        return true;
    }

    static void composite(int width, int height, long colorAddress, long depthAddress) {
        if (failed || colorAddress == 0L || depthAddress == 0L) {
            return;
        }
        if (program == 0 && !init()) {
            failed = true;
            return;
        }

        // ---- save state
        int prevProgram = GL11.glGetInteger(GL20.GL_CURRENT_PROGRAM);
        int prevVao = GL11.glGetInteger(GL30.GL_VERTEX_ARRAY_BINDING);
        int prevActive = GL11.glGetInteger(GL13.GL_ACTIVE_TEXTURE);
        GL13.glActiveTexture(GL13.GL_TEXTURE0);
        int prevTex0 = GL11.glGetInteger(GL11.GL_TEXTURE_BINDING_2D);
        GL13.glActiveTexture(GL13.GL_TEXTURE1);
        int prevTex1 = GL11.glGetInteger(GL11.GL_TEXTURE_BINDING_2D);
        boolean prevBlend = GL11.glIsEnabled(GL11.GL_BLEND);
        int prevSrcRgb = GL11.glGetInteger(GL14.GL_BLEND_SRC_RGB);
        int prevDstRgb = GL11.glGetInteger(GL14.GL_BLEND_DST_RGB);
        int prevSrcA = GL11.glGetInteger(GL14.GL_BLEND_SRC_ALPHA);
        int prevDstA = GL11.glGetInteger(GL14.GL_BLEND_DST_ALPHA);
        boolean prevDepthTest = GL11.glIsEnabled(GL11.GL_DEPTH_TEST);
        int prevDepthFunc = GL11.glGetInteger(GL11.GL_DEPTH_FUNC);
        boolean prevDepthMask = GL11.glGetBoolean(GL11.GL_DEPTH_WRITEMASK);
        boolean prevCull = GL11.glIsEnabled(GL11.GL_CULL_FACE);
        int prevAlign = GL11.glGetInteger(GL11.GL_UNPACK_ALIGNMENT);
        int prevRowLength = GL11.glGetInteger(GL11.GL_UNPACK_ROW_LENGTH);

        try {
            GL13.glActiveTexture(GL13.GL_TEXTURE0);
            GL11.glBindTexture(GL11.GL_TEXTURE_2D, colorTexture);
            ensureTexture(width, height, true);
            GL11.glPixelStorei(GL11.GL_UNPACK_ALIGNMENT, 4);
            GL11.glPixelStorei(GL11.GL_UNPACK_ROW_LENGTH, 0);
            GL11.nglTexSubImage2D(GL11.GL_TEXTURE_2D, 0, 0, 0, width, height,
                    GL12.GL_BGRA, GL11.GL_UNSIGNED_BYTE, colorAddress);

            GL13.glActiveTexture(GL13.GL_TEXTURE1);
            GL11.glBindTexture(GL11.GL_TEXTURE_2D, depthTexture);
            ensureTexture(width, height, false);
            GL11.nglTexSubImage2D(GL11.GL_TEXTURE_2D, 0, 0, 0, width, height,
                    GL11.GL_RED, GL11.GL_FLOAT, depthAddress);

            textureWidth = width;
            textureHeight = height;

            GL11.glDisable(GL11.GL_CULL_FACE);
            GL11.glEnable(GL11.GL_DEPTH_TEST);
            GL11.glDepthFunc(GL11.GL_LEQUAL);
            GL11.glDepthMask(true);
            GL11.glEnable(GL11.GL_BLEND);
            GL14.glBlendFuncSeparate(
                    GL11.GL_ONE, GL11.GL_ONE_MINUS_SRC_ALPHA,
                    GL11.GL_ONE, GL11.GL_ONE_MINUS_SRC_ALPHA);

            GL20.glUseProgram(program);
            GL30.glBindVertexArray(vao);
            GL11.glDrawArrays(GL11.GL_TRIANGLES, 0, 3);
        } finally {
            // ---- restore exactly what was read on entry
            GL11.glPixelStorei(GL11.GL_UNPACK_ALIGNMENT, prevAlign);
            GL11.glPixelStorei(GL11.GL_UNPACK_ROW_LENGTH, prevRowLength);
            GL30.glBindVertexArray(prevVao);
            GL20.glUseProgram(prevProgram);
            GL13.glActiveTexture(GL13.GL_TEXTURE1);
            GL11.glBindTexture(GL11.GL_TEXTURE_2D, prevTex1);
            GL13.glActiveTexture(GL13.GL_TEXTURE0);
            GL11.glBindTexture(GL11.GL_TEXTURE_2D, prevTex0);
            GL13.glActiveTexture(prevActive);
            GL14.glBlendFuncSeparate(prevSrcRgb, prevDstRgb, prevSrcA, prevDstA);
            setEnabled(GL11.GL_BLEND, prevBlend);
            GL11.glDepthFunc(prevDepthFunc);
            GL11.glDepthMask(prevDepthMask);
            setEnabled(GL11.GL_DEPTH_TEST, prevDepthTest);
            setEnabled(GL11.GL_CULL_FACE, prevCull);
        }
    }

    private static void setEnabled(int capability, boolean enabled) {
        if (enabled) {
            GL11.glEnable(capability);
        } else {
            GL11.glDisable(capability);
        }
    }

    private static boolean init() {
        int vs = compile(GL20.GL_VERTEX_SHADER, VERTEX_SHADER);
        int fs = compile(GL20.GL_FRAGMENT_SHADER, FRAGMENT_SHADER);
        if (vs == 0 || fs == 0) {
            return false;
        }
        int linked = GL20.glCreateProgram();
        GL20.glAttachShader(linked, vs);
        GL20.glAttachShader(linked, fs);
        GL20.glLinkProgram(linked);
        GL20.glDeleteShader(vs);
        GL20.glDeleteShader(fs);
        if (GL20.glGetProgrami(linked, GL20.GL_LINK_STATUS) == GL11.GL_FALSE) {
            System.err.println("[Magnesium] Composite shader link failed: "
                    + GL20.glGetProgramInfoLog(linked));
            GL20.glDeleteProgram(linked);
            return false;
        }

        int prevProgram = GL11.glGetInteger(GL20.GL_CURRENT_PROGRAM);
        GL20.glUseProgram(linked);
        GL20.glUniform1i(GL20.glGetUniformLocation(linked, "u_Color"), 0);
        GL20.glUniform1i(GL20.glGetUniformLocation(linked, "u_Depth"), 1);
        GL20.glUseProgram(prevProgram);

        program = linked;
        vao = GL30.glGenVertexArrays();
        colorTexture = GL11.glGenTextures();
        depthTexture = GL11.glGenTextures();
        System.out.println("[Magnesium] Metal -> OpenGL composite shader ready.");
        return true;
    }

    private static int compile(int type, String source) {
        int shader = GL20.glCreateShader(type);
        GL20.glShaderSource(shader, source);
        GL20.glCompileShader(shader);
        if (GL20.glGetShaderi(shader, GL20.GL_COMPILE_STATUS) == GL11.GL_FALSE) {
            System.err.println("[Magnesium] Composite shader compile failed: "
                    + GL20.glGetShaderInfoLog(shader));
            GL20.glDeleteShader(shader);
            return 0;
        }
        return shader;
    }

    /**
     * (Re)allocates the currently bound texture when the frame size changed.
     * Called with the texture already bound on the active unit.
     */
    private static void ensureTexture(int width, int height, boolean color) {
        if (width == textureWidth && height == textureHeight) {
            return;
        }
        if (color) {
            allocate(GL11.GL_RGBA8, width, height, GL11.GL_RGBA, GL11.GL_UNSIGNED_BYTE);
        } else {
            allocate(GL30.GL_R32F, width, height, GL11.GL_RED, GL11.GL_FLOAT);
        }
    }

    private static void allocate(int internalFormat, int width, int height, int format, int type) {
        GL11.glTexImage2D(GL11.GL_TEXTURE_2D, 0, internalFormat, width, height, 0,
                format, type, 0L);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_MIN_FILTER, GL11.GL_NEAREST);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_MAG_FILTER, GL11.GL_NEAREST);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_WRAP_S, GL13.GL_CLAMP_TO_EDGE);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_WRAP_T, GL13.GL_CLAMP_TO_EDGE);
        GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL12.GL_TEXTURE_MAX_LEVEL, 0);
    }
}
