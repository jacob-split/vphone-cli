OUT := VPhoneAX.dylib
VENDOR := vendor/ios-mcp
VENDOR_SRCS := $(VENDOR)/MCPAXAttributeBridge.m $(VENDOR)/MCPAXNodeSource.m $(VENDOR)/MCPAXQueryContext.m $(VENDOR)/MCPAXRemoteContextResolver.m
SRCS := VPhoneAX.m VPhoneAXRuntime.m VPhoneAXBroker.m VPhoneAXLog.m MCPLogger.m $(VENDOR_SRCS)
HEADERS := $(wildcard *.h) $(wildcard $(VENDOR)/*.h)

.PHONY: all clean
all: $(OUT)

$(OUT): $(SRCS) $(HEADERS)
	@echo "=== Building VPhoneAX (arm64 + arm64e) ==="
	xcrun -sdk iphoneos clang -arch arm64 -arch arm64e -miphoneos-version-min=15.0 \
		-dynamiclib -fobjc-arc -Os -I. -I$(VENDOR) \
		-Wl,-undefined,dynamic_lookup \
		-framework Foundation -framework UIKit -framework CoreGraphics \
		-o $@ $(SRCS)
	@echo "  built → $@"

clean:
	rm -f $(OUT)
