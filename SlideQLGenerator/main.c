/*
 * CFPlugin main for Quick Look Generator
 * Based on Apple's QuickLook Generator template
 */

#include <CoreFoundation/CFPlugInCOM.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreServices/CoreServices.h>
#include <QuickLook/QuickLook.h>

// Forward declarations for generator callbacks
OSStatus GeneratePreviewForURL(void *thisInterface, QLPreviewRequestRef preview,
                               CFURLRef url, CFStringRef contentTypeUTI,
                               CFDictionaryRef options);
void CancelPreviewGeneration(void *thisInterface, QLPreviewRequestRef preview);

OSStatus GenerateThumbnailForURL(void *thisInterface,
                                 QLThumbnailRequestRef thumbnail, CFURLRef url,
                                 CFStringRef contentTypeUTI,
                                 CFDictionaryRef options, CGSize maxSize);
void CancelThumbnailGeneration(void *thisInterface,
                               QLThumbnailRequestRef thumbnail);

// The QL generator UUID - must match Info.plist
#define PLUGIN_ID CFSTR("A1B2C3D4-E5F6-7890-ABCD-EF1234567890")

static UInt32 _refCount = 0;

// IUnknown
static HRESULT myQueryInterface(void *thisInterface, REFIID iid, LPVOID *ppv) {
  CFUUIDRef interfaceID = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, iid);
  if (CFEqual(interfaceID, kQLGeneratorCallbacksInterfaceID)) {
    ((QLGeneratorInterfaceStruct *)thisInterface)->AddRef(thisInterface);
    *ppv = thisInterface;
    CFRelease(interfaceID);
    return S_OK;
  }
  if (CFEqual(interfaceID, IUnknownUUID)) {
    ((QLGeneratorInterfaceStruct *)thisInterface)->AddRef(thisInterface);
    *ppv = thisInterface;
    CFRelease(interfaceID);
    return S_OK;
  }
  *ppv = NULL;
  CFRelease(interfaceID);
  return E_NOINTERFACE;
}

static ULONG myAddRef(void *thisInterface) {
  _refCount++;
  return _refCount;
}

static ULONG myRelease(void *thisInterface) {
  _refCount--;
  if (_refCount == 0) {
    free(thisInterface);
    return 0;
  }
  return _refCount;
}

// Create the interface - order matches QLGeneratorInterfaceStruct:
// _reserved, QueryInterface, AddRef, Release,
// GenerateThumbnailForURL, CancelThumbnailGeneration,
// GeneratePreviewForURL, CancelPreviewGeneration
static QLGeneratorInterfaceStruct myInterfaceVtbl = {NULL,
                                                     myQueryInterface,
                                                     myAddRef,
                                                     myRelease,
                                                     GenerateThumbnailForURL,
                                                     CancelThumbnailGeneration,
                                                     GeneratePreviewForURL,
                                                     CancelPreviewGeneration};

// Factory function
void *QuickLookGeneratorPluginFactory(CFAllocatorRef allocator,
                                      CFUUIDRef typeID) {
  if (CFEqual(typeID, kQLGeneratorTypeID)) {
    QLGeneratorInterfaceStruct *result = (QLGeneratorInterfaceStruct *)malloc(
        sizeof(QLGeneratorInterfaceStruct));
    memcpy(result, &myInterfaceVtbl, sizeof(QLGeneratorInterfaceStruct));
    myAddRef(result);
    return result;
  }
  return NULL;
}
