/+dub.sdl:
name "imgstack"

dependency "imageformats" version="~>7.0.2"
+/

import std.algorithm;
import std.exception;
import std.experimental.logger;
import std.file;
import std.format;
import std.getopt;
import std.parallelism;
import std.path;
import std.range;
import std.stdio;

import imageformats;

enum Op
{
    sum,
    min,
    max,
    average,
    median,
}

int main(string[] args)
{
    string darkframe;
    string outFile;
    Op operation = Op.average;
    bool overwrite = false;
    
    auto res = args.getopt(
        "op", "Stacking operation to perform", &operation,
        "d|darkframe", "Dark frame image to subtract before stacking frames", &darkframe,
        std.getopt.config.required, "o|out", "Output file", &outFile,
        "y|overwrite", "Force overwrite output file", &overwrite,
    );
    
    if(res.helpWanted)
    {
        defaultGetoptPrinter("imgstack", res.options);
        
        return 0;
    }
    
    if(!overwrite && outFile.exists)
    {
        error("output file exists, refusing to overwrite");
        
        return 1;
    }
    
    if(darkframe != null && !darkframe.exists)
    {
        error("dark frame file does not exist");
        
        return 1;
    }
    
    args = args[1 .. $];
    
    foreach(file; args)
        if(!file.exists)
        {
            errorf("input file `%s` does not exist", file);
            
            return 1;
        }
    
    IFImage outImg;
    
    switch(operation)
    {
        case Op.median:
            outImg = median(args, darkframe);
            break;
        case Op.average:
        case Op.sum:
            outImg = avgSum(args, darkframe, operation == Op.sum);
            break;
        case Op.min:
        case Op.max:
            outImg = minMax(args, darkframe, operation == Op.max);
            break;
        default:
            throw new Exception("todo");
    }
    
    write_image(outFile, outImg.w, outImg.h, outImg.pixels, ColFmt.RGB);
    info("Wrote output file ", outFile);
    
    return 0;
}

Out[length] arrayCast(Out, Arr: In[length], In, size_t length)(Arr v)
{
    Out[length] result;
    
    static foreach(index; 0 .. length)
        result[index] = cast(Out)v[index];
    
    return result;
}

ubyte[] loadDarkframe(string file, int width, int height)
{
    ubyte[] result = null;
    
    if(file.length > 0)
    {
        auto img = read_image(file, ColFmt.RGB);
        
        enforce(img.w == width && img.h == height, "mismatched dark frame dimensions");
        logf("loaded dark frame %s", file);
        
        result = img.pixels;
    }
    
    return result;
}

IFImage avgSum(string[] inputFiles, string darkframeFile = null, bool sum = false)
{
    enforce(inputFiles.length > 0);
    
    int w, h, channels;
    
    read_image_info(inputFiles[0], w, h, channels);
    
    ulong[] stackbuf = new ulong[w * h * 3];
    auto darkframe = loadDarkframe(darkframeFile, w, h);
    
    foreach(file; inputFiles)
    {
        auto img = read_image(file, ColFmt.RGB);
        
        enforce(img.w == w && img.h == h, "mismatched image dimensions on %s (%dx%d vs %dx%d)".format(file, w, h, img.w, img.h));
        logf("stacking image %s", file);
        
        foreach(y; iota(h).parallel)
            foreach(x; 0 .. w)
            {
                const index = (y * w + x) * 3;
                ubyte[3] sample = img.pixels.ptr[index .. index + 3];
                
                if(darkframe != null)
                    sample[] -= darkframe.ptr[index .. index + 3][];
                
                auto wideSample = arrayCast!ulong(sample);
                stackbuf.ptr[index .. index + 3][] += wideSample[];
            }
    }
    
    if(!sum) stackbuf[] /= inputFiles.length;
    auto result = IFImage(w, h, ColFmt.RGB, new ubyte[w * h * 3]);
    
    foreach(y; iota(h).parallel)
        foreach(x; 0 .. w)
        {
            const index = (w * y + x) * 3;
            ulong[3] val = stackbuf[index .. index + 3];
            auto thin = arrayCast!ubyte(val);
            result.pixels.ptr[index .. index + 3] = thin;
        }
    
    return result;
}

IFImage median(string[] inputFiles, string darkframeFile)
{
    enforce(inputFiles.length > 0);
    
    int w, h, channels;
    
    read_image_info(inputFiles[0], w, h, channels);
    
    ubyte[] darkframe = loadDarkframe(darkframeFile, w, h);
    IFImage[] images = inputFiles
        .tee!(f => {
            import core.memory: GC;
            
            logf("loading frame %s", f);
            log("mem: %1.2fm/%1.2fm used", GC.stats.allocatedInCurrentThread / 1024.0 / 1024.0, GC.stats.freeSize / 1024.0 / 1024.0);
        })
        .map!(f => read_image(f, ColFmt.RGB))
        .array
    ;
    auto result = IFImage(w, h, ColFmt.RGB, new ubyte[w * h * 3]);
    
    foreach(y; iota(h).parallel)
        foreach(x; 0 .. w)
        {
            const index = (y * w + x) * 3;
            auto samples = images.map!(img => img.pixels.ptr[index .. index + 3]).array;
            
            if(darkframe != null)
                foreach(ref sample; samples)
                    sample[] -= darkframe.ptr[index .. index + 3][];
            
            ubyte[3] sample;
            
            foreach(chan; 0 .. 3)
                sample[chan] = samples.map!(pixel => pixel[chan]).medianOf;
            
            result.pixels.ptr[index .. index + 3] = sample[];
        }
    
    return result;
}

ElementType!Range medianOf(Range)(Range r)
{
    auto copy = r.array;
    copy.sort!();
    
    if(copy.length & 1)
        return copy[$ / 2];
    else
        return (copy[$ / 2 - 1] + copy[$ / 2]) / 2;
}

IFImage minMax(string[] inputFiles, string darkframeFile, bool maxVal)
{
    enforce(inputFiles.length > 0);
    
    int w, h, channels;
    
    read_image_info(inputFiles[0], w, h, channels);
    
    ubyte[] darkframe = loadDarkframe(darkframeFile, w, h);
    auto result = IFImage(w, h, ColFmt.RGB, new ubyte[w * h * 3]);
    
    // when getting minval, must start from brightest possible pixel value
    if(!maxVal) result.pixels[] = ubyte.max;
    
    foreach(file; inputFiles)
    {
        auto img = read_image(file, ColFmt.RGB);
        
        enforce(img.w == w && img.h == h, "mismatched image dimensions on %s (%dx%d vs %dx%d)".format(file, w, h, img.w, img.h));
        logf("stacking image %s", file);
        
        foreach(y; iota(h).parallel)
            foreach(x; 0 .. w)
            {
                const index = (y * w + x) * 3;
                ubyte[3] sample = img.pixels.ptr[index .. index + 3];
                
                if(darkframe != null)
                    sample[] -= darkframe.ptr[index .. index + 3][];
                
                foreach(i, ref v; result.pixels.ptr[index .. index + 3])
                    v = maxVal ? max(v, sample[i]) : min(v, sample[i]);
            }
    }
    
    return result;
}
