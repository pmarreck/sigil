#!/usr/bin/env luajit

-- Benchmark script to compare original vs optimized printable_binary performance
-- This script measures encoding and decoding performance for various input sizes

local socket = require("socket")

-- Configuration
local ITERATIONS = 10  -- Number of iterations per test
local TEST_SIZES = {100, 1000, 10000, 100000}  -- Byte sizes to test

-- Utilities
local function generate_test_data(size, pattern)
    if pattern == "binary" then
        -- Generate all possible byte values in sequence
        local data = {}
        for i = 1, size do
            data[i] = string.char((i - 1) % 256)
        end
        return table.concat(data)
    elseif pattern == "ascii" then
        -- Generate ASCII text
        local data = {}
        for i = 1, size do
            local char_code = 32 + ((i - 1) % 95)  -- Printable ASCII range
            data[i] = string.char(char_code)
        end
        return table.concat(data)
    elseif pattern == "random" then
        -- Generate random bytes
        math.randomseed(12345)  -- Fixed seed for reproducibility
        local data = {}
        for i = 1, size do
            data[i] = string.char(math.random(0, 255))
        end
        return table.concat(data)
    end
end

local function write_temp_file(data)
    local temp_file = os.tmpname()
    local file = io.open(temp_file, "wb")
    file:write(data)
    file:close()
    return temp_file
end

local function benchmark_script(script_path, operation, input_file, iterations)
    local times = {}
    
    for i = 1, iterations do
        local start_time = socket.gettime()
        
        local cmd
        if operation == "encode" then
            cmd = script_path .. " \"" .. input_file .. "\" > /dev/null 2>&1"
        else  -- decode
            cmd = script_path .. " -d \"" .. input_file .. "\" > /dev/null 2>&1"
        end
        
        local result = os.execute(cmd)
        local end_time = socket.gettime()
        
        if result ~= 0 and result ~= true then
            error("Command failed: " .. cmd)
        end
        
        times[i] = end_time - start_time
    end
    
    -- Calculate statistics
    table.sort(times)
    local sum = 0
    for _, time in ipairs(times) do
        sum = sum + time
    end
    
    return {
        min = times[1],
        max = times[#times],
        avg = sum / #times,
        median = times[math.ceil(#times / 2)]
    }
end

local function format_time(seconds)
    if seconds < 0.001 then
        return string.format("%.2f μs", seconds * 1000000)
    elseif seconds < 1 then
        return string.format("%.2f ms", seconds * 1000)
    else
        return string.format("%.2f s", seconds)
    end
end

local function print_results(size, pattern, operation, original_stats, optimized_stats)
    local speedup = original_stats.avg / optimized_stats.avg
    local improvement = ((original_stats.avg - optimized_stats.avg) / original_stats.avg) * 100
    
    print(string.format("Size: %d bytes, Pattern: %s, Operation: %s", size, pattern, operation))
    print(string.format("  Original:  avg=%s, min=%s, max=%s", 
        format_time(original_stats.avg), 
        format_time(original_stats.min), 
        format_time(original_stats.max)))
    print(string.format("  Optimized: avg=%s, min=%s, max=%s", 
        format_time(optimized_stats.avg), 
        format_time(optimized_stats.min), 
        format_time(optimized_stats.max)))
    print(string.format("  Speedup: %.2fx (%.1f%% improvement)", speedup, improvement))
    print("")
end

-- Main benchmark execution
local function run_benchmark()
    print("PrintableBinary Performance Benchmark")
    print("=====================================")
    print("")
    
    local original_script = "./bin/printable-binary-luajit"
    local optimized_script = "./printable_binary_optimized"
    
    -- Check if both scripts exist
    local original_exists = os.execute("test -f " .. original_script) == 0 or os.execute("test -f " .. original_script) == true
    local optimized_exists = os.execute("test -f " .. optimized_script) == 0 or os.execute("test -f " .. optimized_script) == true
    
    if not original_exists then
        print("Error: Original script not found: " .. original_script)
        os.exit(1)
    end
    
    if not optimized_exists then
        print("Error: Optimized script not found: " .. optimized_script)
        os.exit(1)
    end
    
    print("Testing with " .. ITERATIONS .. " iterations per test")
    print("Test sizes: " .. table.concat(TEST_SIZES, ", ") .. " bytes")
    print("")
    
    local patterns = {"ascii", "binary", "random"}
    local operations = {"encode", "decode"}
    
    local temp_files = {}
    
    -- Generate test data files
    for _, pattern in ipairs(patterns) do
        temp_files[pattern] = {}
        for _, size in ipairs(TEST_SIZES) do
            local data = generate_test_data(size, pattern)
            local temp_file = write_temp_file(data)
            temp_files[pattern][size] = temp_file
            
            if pattern == "ascii" then
                -- For decode testing, we need encoded data
                local encoded_temp_file = os.tmpname()
                local encode_cmd = original_script .. " \"" .. temp_file .. "\" > \"" .. encoded_temp_file .. "\" 2>/dev/null"
                os.execute(encode_cmd)
                temp_files[pattern][size .. "_encoded"] = encoded_temp_file
            end
        end
    end
    
    -- Run benchmarks
    for _, pattern in ipairs(patterns) do
        print("Pattern: " .. string.upper(pattern))
        print(string.rep("-", 40))
        
        for _, size in ipairs(TEST_SIZES) do
            for _, operation in ipairs(operations) do
                local input_file
                if operation == "encode" then
                    input_file = temp_files[pattern][size]
                else
                    -- For decode, we need encoded data
                    if pattern == "ascii" then
                        input_file = temp_files[pattern][size .. "_encoded"]
                    else
                        -- Generate encoded version for binary/random patterns
                        local encoded_temp_file = os.tmpname()
                        local encode_cmd = original_script .. " \"" .. temp_files[pattern][size] .. "\" > \"" .. encoded_temp_file .. "\" 2>/dev/null"
                        os.execute(encode_cmd)
                        input_file = encoded_temp_file
                    end
                end
                
                local original_stats = benchmark_script(original_script, operation, input_file, ITERATIONS)
                local optimized_stats = benchmark_script(optimized_script, operation, input_file, ITERATIONS)
                
                print_results(size, pattern, operation, original_stats, optimized_stats)
            end
        end
    end
    
    -- Cleanup temp files
    for pattern, files in pairs(temp_files) do
        for _, file in pairs(files) do
            os.remove(file)
        end
    end
end

-- Memory usage comparison
local function run_memory_test()
    print("Memory Usage Comparison")
    print("======================")
    print("")
    
    local test_size = 10000
    local test_data = generate_test_data(test_size, "binary")
    local temp_file = write_temp_file(test_data)
    
    -- This is a simple test - more sophisticated memory profiling would require external tools
    print("Note: For detailed memory analysis, use tools like:")
    print("  - valgrind --tool=massif")
    print("  - time -v")
    print("  - /usr/bin/time -l (on macOS)")
    print("")
    
    local function test_memory(script, name)
        print("Testing " .. name .. "...")
        local cmd = "/usr/bin/time -l " .. script .. " \"" .. temp_file .. "\" > /dev/null 2>&1"
        print("Command: " .. cmd)
        os.execute(cmd)
        print("")
    end
    
    test_memory("./bin/printable-binary-luajit", "Original")
    test_memory("./printable_binary_optimized", "Optimized")
    
    os.remove(temp_file)
end

-- Run the benchmarks
print("Starting benchmark...")
print("")

run_benchmark()
run_memory_test()

print("Benchmark completed!")
