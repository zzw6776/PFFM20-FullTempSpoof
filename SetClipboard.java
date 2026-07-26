import java.io.File;
import java.io.FileInputStream;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;

public class SetClipboard {
    public static void main(String[] args) {
        if (args.length == 0) {
            System.err.println("Usage: java SetClipboard <file_path>");
            System.exit(1);
        }
        String filePath = args[0];
        try {
            File file = new File(filePath);
            FileInputStream fis = new FileInputStream(file);
            byte[] data = new byte[(int) file.length()];
            fis.read(data);
            fis.close();
            
            String text = new String(data, StandardCharsets.UTF_8);
            
            // Reflection logic to set clipboard
            Class<?> serviceManagerClass = Class.forName("android.os.ServiceManager");
            Method getServiceMethod = serviceManagerClass.getMethod("getService", String.class);
            Object binder = getServiceMethod.invoke(null, "clipboard");
            
            if (binder == null) {
                System.err.println("Failed to get clipboard service.");
                System.exit(3);
            }
            
            Class<?> iClipboardStubClass = Class.forName("android.content.IClipboard$Stub");
            Method asInterfaceMethod = iClipboardStubClass.getMethod("asInterface", Class.forName("android.os.IBinder"));
            Object iClipboardService = asInterfaceMethod.invoke(null, binder);
            
            Class<?> clipDataClass = Class.forName("android.content.ClipData");
            Method newPlainTextMethod = clipDataClass.getMethod("newPlainText", CharSequence.class, CharSequence.class);
            Object clipData = newPlainTextMethod.invoke(null, "label", text);
            
            // Find setPrimaryClip method dynamically to support different Android versions (3 or 4 arguments)
            Method setPrimaryClipMethod = null;
            for (Method method : iClipboardService.getClass().getMethods()) {
                if (method.getName().equals("setPrimaryClip")) {
                    setPrimaryClipMethod = method;
                    break;
                }
            }
            
            if (setPrimaryClipMethod == null) {
                System.err.println("setPrimaryClip method not found.");
                System.exit(4);
            }
            
            Class<?>[] paramTypes = setPrimaryClipMethod.getParameterTypes();
            Object[] invokeArgs = new Object[paramTypes.length];
            invokeArgs[0] = clipData; // First param is always ClipData
            
            if (paramTypes.length == 3) {
                // setPrimaryClip(ClipData clip, String callingPackage, int userId)
                invokeArgs[1] = "com.android.shell";
                invokeArgs[2] = 0; // userId
            } else if (paramTypes.length == 4) {
                // setPrimaryClip(ClipData clip, String callingPackage, String attributionTag, int userId)
                invokeArgs[1] = "com.android.shell";
                invokeArgs[2] = null; // attributionTag
                invokeArgs[3] = 0; // userId
            } else if (paramTypes.length == 5) {
                // setPrimaryClip(ClipData clip, String callingPackage, String attributionTag, int userId, int userSerial)
                invokeArgs[1] = "com.android.shell";
                invokeArgs[2] = null;
                invokeArgs[3] = 0;
                invokeArgs[4] = 0;
            } else {
                System.err.println("Unsupported setPrimaryClip parameter count: " + paramTypes.length);
                System.exit(5);
            }
            
            setPrimaryClipMethod.invoke(iClipboardService, invokeArgs);
            System.out.println("Clipboard set successfully from file!");
        } catch (Exception e) {
            e.printStackTrace();
            System.exit(2);
        }
    }
}
