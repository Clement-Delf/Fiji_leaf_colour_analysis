/* ============================================================
    leaf_segmentation_colorstats.ijm  -  v2.1  (IJ1 macro language)
    Fiji/ImageJ - Leaf segmentation on a cyan/turquoise background
    CIELab b* channel thresholding + RGB and Lab histogram export
    + export of one crop per leaf and all leaves combined
  
    Compatibility: Fiji (ImageJ 1.x macro language, IJ ≥ 1.53)
                   No additional plugins required
  
    Usage:
      1. Open the RGB image in Fiji.
      2. Plugins > Macros > Run... -> select this file.
      3. If the image has not been saved to disk, a dialog box
         asks for the output directory.
   ============================================================*/


// --- USER PARAMETERS ---

// -- b* channel thresholding --
// Cyan background -> very negative b* -> dark pixels after 8-bit normalization
// Green leaves -> positive b* -> lighter pixels
USE_AUTO_THRESHOLD = true;       // false = use MANUAL_THRESH
MANUAL_THRESH      = 128;        // manual threshold [0–255] (8-bit b*)
AUTO_METHOD        = "Otsu dark";// alternatives: "Triangle dark", "Li dark"

// -- Morphological cleaning --
// Number of successive erosions applied to the mask.
ERODE_RADIUS  = 10;    // binary erosion radius in pixels 
MIN_OBJECT_PX = 1;     // minimum area of retained objects (px²)

// --- END OF PARAMETERS ---


// ============================================================
//  STEP 1 - Verification, file names, output directory
// ============================================================

if (nImages() == 0)
    exit("No image is open.\nOpen an RGB image before running this macro.");

origID    = getImageID();
origTitle = getTitle();

// --- baseName cleaning ---
// origTitle may be e.g. "img20260622_16095350.tif (RGB)"
// -> remove parenthesized suffixes, then the extension.

cleanTitle = origTitle;

// Loop: remove the last " (...)" or terminal "(...)"
while (endsWith(cleanTitle, ")")) {
    parenOpen = lastIndexOf(cleanTitle, " (");
    if (parenOpen < 0)
        parenOpen = lastIndexOf(cleanTitle, "(");
    if (parenOpen >= 0)
        cleanTitle = substring(cleanTitle, 0, parenOpen);
    else
        cleanTitle = substring(cleanTitle, 0, lengthOf(cleanTitle) - 1);
}
cleanTitle = String.trim(cleanTitle);

// Remove the file extension (.tif, .png, .jpg ...)
dotPos = lastIndexOf(cleanTitle, ".");
if (dotPos > 0)
    baseName = substring(cleanTitle, 0, dotPos);
else
    baseName = cleanTitle;

// --- Output directory ---
origDir = getDirectory("image");
if (origDir == "") {
    // Image has not been saved yet -> dialog box
    origDir = getDirectory("Choose the output directory for the results");
}

// --- Reset ROI Manager ---
roiManager("Reset");

print("=== Leaf Segmentation v2.1 - starting ===");
print("Image    : " + origTitle);
print("BaseName : " + baseName);
print("Directory: " + origDir);


// ============================================================
//  STEP 2 - Duplicate the original
//  (NEVER modify the original image; work on the copy)
// ============================================================
selectImage(origID);
run("Duplicate...", "title=work_rgb");
workID = getImageID();


// ============================================================
//  STEP 3 - RGB -> CIELab conversion
//
//  run("Lab Stack") is a built-in Fiji command:
//  converts the 24-bit RGB image into a 3-slice 32-bit stack:
//    Slice 1 = L*   luminance     [0 ; 100]
//    Slice 2 = a*   green <-> red  [-128 ; +127]
//    Slice 3 = b*   blue <-> yellow [-128 ; +127]
//
//  Cyan background (blue-dominant) -> very negative b*
//  Green leaves                     -> slightly positive or ~0 b*
// ============================================================
selectImage(workID);
run("Lab Stack");
labStackID = getImageID();
rename("lab_stack");

// Copy the Lab stack for histogram export (Step 10)
// Work on the copy to avoid modifying the main stack
selectImage(labStackID);
run("Duplicate...", "title=lab_for_histo duplicate");
labHistoID = getImageID();
print("RGB->Lab conversion completed.");


// ============================================================
//  STEP 4 - Extract b* channel (slice 3) + convert to 8-bit
//
//  Duplicate slice 3 of the Lab stack, then convert it to 8-bit
//  using contrast enhancement without saturation.
//  Result: cyan background pixels ≈ 0–50, leaves ≈ 150–255
// ============================================================
selectImage(labStackID);
setSlice(3);
run("Duplicate...", "title=bstar_32bit");
bstar32ID = getImageID();

selectImage(bstar32ID);
run("Enhance Contrast", "saturated=0.35");
run("8-bit");
rename("bstar_8bit");
bstar8ID = getImageID();
print("b* channel extracted and converted to 8-bit.");


// ============================================================
//  STEP 5 - Threshold b* channel -> binary mask
//
//  Light pixels (high b*) = leaves -> 255 (white)
//  Dark pixels (low b*)   = cyan background -> 0 (black)
//
//  run("Convert to Mask") uses the active threshold to produce
//  a strictly binary 0 / 255 image.
// ============================================================
selectImage(bstar8ID);

if (USE_AUTO_THRESHOLD) {
    setAutoThreshold(AUTO_METHOD);
    run("Convert to Mask");
    print("Automatic thresholding: " + AUTO_METHOD);
} else {
    setThreshold(MANUAL_THRESH, 255);
    run("Convert to Mask");
    print("Manual threshold: normalized b* > " + MANUAL_THRESH);
}

rename("mask_raw");
maskRawID = getImageID();


// ============================================================
//  STEP 6 - Morphological cleaning of the mask
//
//  Several operations are applied successively:
//    a) Despeckle
//       -> reduces local noise.
//
//    b) Fill Holes
//       -> fills areas completely surrounded by
//         segmented objects.
//
//    c) Open
//       -> erosion followed by dilation; reduces small objects
//         and thin connections.
//
//    d) Close
//       -> dilation followed by erosion; fills small
//         discontinuities and gaps in the mask.
//
//    e) Erode × ERODE_RADIUS
//       -> deliberately reduces object size and removes
//         fine structures.
//
//    f) Dilate
//       -> partially restores object size
//         after erosion.
//
//     -> produces a new "mask_clean" containing the filtered objects
// ============================================================
selectImage(maskRawID);
run("Duplicate...", "title=mask_work");
maskWorkID = getImageID();

selectImage(maskWorkID);

run("8-bit");
run("Make Binary");

run("Despeckle");
run("Fill Holes");

run("Open");
run("Close");

// optional light cleaning
for(i=0; i<ERODE_RADIUS; i++) {
    run("Erode");
}

run("Dilate");

// Final ROI mask
rename("mask_clean");
maskCleanID = getImageID();

getStatistics(area, mean, min, max);
print("mask_clean stats: min=" + min + " max=" + max + " mean=" + mean);

// ============================================================
//  STEP 7 - Convert clean mask into ROI selection
//
//  The clean mask is reconverted to a binary mask, then
//  Analyze Particles identifies the objects corresponding to
//  the segmented leaves.
//
//  Objects with an area smaller than MIN_OBJECT_PX
//  are excluded.
//
//  The "add" option adds detected particles to the ROI Manager.
//  A global selection is then created from the mask
//  and added to the ROI Manager.
// ============================================================
selectImage(maskCleanID);

run("Select None");

roiManager("Reset");

run("8-bit");
setAutoThreshold(AUTO_METHOD);
setOption("BlackBackground", true);
run("Convert to Mask");
run("Make Binary");

run("Analyze Particles...",
    "size=" + MIN_OBJECT_PX + "-Infinity add display clear"); // change to 2-Infinity to threshold the minimum size of retained leaves

print("ROI count = " + roiManager("count"));

run("Create Selection"); 
roiManager("Add");
print("ROI created and added to ROI Manager (index 0).");

// ============================================================
//  STEP 8 - Overlay leaf outlines on the original image
//
//  run("Add Selection...") adds the ROI as a vector overlay:
//  the original pixels remain unchanged for measurements.
// ============================================================
selectImage(origID);

nROIs = roiManager("count");

for (r = 0; r < nROIs; r++) {
    roiManager("Select", r);
    run("Add Selection...", "stroke=yellow width=2");
}

print("Overlay contours added (" + nROIs + " leaves).");

selectImage(origID);


// ============================================================
//  STEP 9 - Export RGB histograms (leaf pixels only)
//
//  Protocol:
//    1. Duplicate the original into an image named "rgb_for_split".
//    2. Save the IDs of all images open before splitting.
//    3. run("Split Channels") -> creates 3 new 8-bit grayscale images.
//    4. Identify the new images by comparing the ID lists.
//    5. Apply the ROI to each channel -> getHistogram() -> CSV.
//
//  Note: Split Channels produces titles "C1-<source_title>",
//  but IDs are used (more robust than titles) to
//  select each channel.
// ============================================================

outRoot = origDir + baseName + "/";
File.makeDirectory(outRoot);

// Duplicate the original with a fixed and predictable title.
// -> retrieve IDs using these deterministic titles (no collision possible)
rgbChanNames = newArray("R", "G", "B");

nROIs = roiManager("count");

// Start from the already duplicated/split RGB image
// or better: perform a clean split here

selectImage(origID);
run("Select None");
roiManager("Deselect");
run("Duplicate...", "title=rgb_for_split");
run("Select None");
run("Split Channels");

titles = getList("image.titles");

// retrieve channels cleanly
chanIDs = newArray(3);
k = 0;

for (i = 0; i < titles.length; i++) {
    if (indexOf(titles[i], "rgb_for_split") != -1) {
        selectWindow(titles[i]);
        chanIDs[k] = getImageID();
        k++;
    }
}

if (k != 3) exit("RGB split error");

for (r = 0; r < nROIs; r++) {
    leafDir = outRoot + "leaf_" + r + "/";
    File.makeDirectory(leafDir);

    leafPrefix = "leaf_" + r;

    roiManager("Select", r);

    for (c = 0; c < 3; c++) {

        selectImage(chanIDs[c]);
        
        run("Select None");
        roiManager("Deselect");
        run("Duplicate...", "title=rgb_channel_tmp");
        tmpRGBID = getImageID();
    
        // apply ROI to current channel
        roiManager("Select", r);
        run("Clear Outside");

        // histogram
        binValues = newArray(256);
        binCounts = newArray(256);
        getHistogram(binValues, binCounts, 256);

        csvPath = leafDir + leafPrefix +
            "_" + rgbChanNames[c] + ".csv";

        saveHistogramCSV(binValues, binCounts, csvPath,
            "RGB_" + rgbChanNames[c] + "_" + leafPrefix);
            
        close();
    }
}

print("RGB histograms saved for each leaf.");

selectImage(labHistoID);


// ============================================================
//  STEP 10 - Export Lab histograms (leaf pixels only)
//
//  For each slice of the Lab stack (L*, a*, b*):
//    1. Duplicate the slice (32-bit).
//    2. Mask pixels outside the leaf (fill the outside ROI with 0).
//    3. Apply the ROI -> getHistogram() -> CSV.
//    4. Preserve the original 32-bit range in the CSV header.
//
//  Masking the outside before conversion ensures that
//  background pixels do not influence contrast enhancement.
// ============================================================
outRoot = origDir + baseName + "/";

labChanNames = newArray("L", "a", "b");

nROIs = roiManager("count");

for (r = 0; r < nROIs; r++) {
    selectImage(labHistoID);

    roiManager("Select", r);

    for (s = 1; s <= 3; s++) {
        leafDir = outRoot + "leaf_" + r + "/";
        File.makeDirectory(leafDir);
        leafPrefix = "leaf_" + r;

        selectImage(labHistoID);
        setSlice(s);
        
        run("Select None");
        roiManager("Deselect");
        run("Duplicate...", "title=lab_slice_tmp");
        sliceTmpID = getImageID();
        selectImage(sliceTmpID);
    
        // 32-bit statistics
        getStatistics(dummy, labMean, labMin, labMax);
        rangeNote = "32bit_range=[" + d2s(labMin, 3) + ";" + d2s(labMax, 3) + "]";
        print(rangeNote);
        
        // Mask outside the ROI (LEAF r only)
        roiManager("Select", r);
        run("Clear Outside");
        run("Select None");

        roiManager("Select", r);

        binValues = newArray(256);
        binCounts = newArray(256);
        
        getHistogram(binValues, binCounts, 256);

        csvPath = leafDir + leafPrefix + "_Lab_" + labChanNames[s-1] + ".csv";
        csvLabel = "Lab_" + labChanNames[s-1] + "_" + leafPrefix + "_(" + rangeNote + ")";

        saveHistogramCSV(binValues, binCounts, csvPath, csvLabel);
        
        selectImage(sliceTmpID);
        close();
    }
}

print("Lab histograms saved for each leaf.");


// ============================================================
//  STEP 11 - Save one crop per leaf
//
//  For each ROI:
//
//    1. Select the ROI on the original RGB image.
//    2. Duplicate the image.
//    3. Remove pixels outside the ROI.
//    4. Crop the image around the ROI.
//    5. Save the result as PNG.
//
//  The resulting file therefore contains only the crop of the
//  corresponding leaf.
//
//  This step does not flatten the overlay.
// ============================================================

for (r = 0; r < nROIs; r++) {
    run("Select None");
    roiManager("Deselect");
    
    selectImage(origID);
    roiManager("Select", r);
    run("Duplicate...", "title=rgb_leaf_tmp");
    tmpID = getImageID();

    run("Clear Outside");
    run("Crop");

    leafDir = outRoot + "leaf_" + r + "/";
    File.makeDirectory(leafDir);

    saveAs("PNG", leafDir + "leaf_" + r + ".png");

    close();
}

print("RGB crop saved for each leaf.");


// ============================================================
//  STEP 12 - Clean up intermediate images
// ============================================================
// Close working images by title
// (images saved with saveAs have their title changed
//  -> IDs are used for images that need to be preserved)

tempTitles = newArray(
    "lab_stack",
    "lab_for_histo",
    "bstar_32bit",
    "bstar_8bit",
    "mask_raw",
    "mask_clean",
    "work_rgb",
    "rgb_for_split"
);
for (i = 0; i < tempTitles.length; i++) {
    if (isOpen(tempTitles[i])) {
        selectWindow(tempTitles[i]);
        close();
    }
}
print("Intermediate images closed.");


// --- Final display ---
selectImage(origTitle);   // bring the original image to the foreground

print("");
print("=== Macro completed successfully ===");
print("Files produced in: " + origDir);
print("  [PNG] " + baseName + "_mask.png");
print("  [PNG] " + baseName + "_overlay.png");
print("  [CSV] " + baseName + "_histo_Red.csv");
print("  [CSV] " + baseName + "_histo_Green.csv");
print("  [CSV] " + baseName + "_histo_Blue.csv");
print("  [CSV] " + baseName + "_histo_LabL.csv");
print("  [CSV] " + baseName + "_histo_Laba.csv");
print("  [CSV] " + baseName + "_histo_Labb.csv");


// ============================================================
//  FUNCTION - saveHistogramCSV
//
//  Parameters:
//    binValues[] : array of bin center values (0–255)
//                  from getHistogram(values, counts, 256)
//    binCounts[] : array containing the number of pixels per bin
//    filePath    : full path of the CSV file to create
//    label       : channel name (column Count header)
//
//  CSV format:
//    Bin,<label>_Count
//    0,<count>
//    1,<count>
//    ...
//    255,<count>
// ============================================================
function saveHistogramCSV(binValues, binCounts, filePath, label) {

    f = File.open(filePath);

    print(f, "Bin," + label + "_Count");

    for (b = 0; b < 256; b++) {
        print(f, b + "," + binCounts[b]);
    }

    File.close(f);
}