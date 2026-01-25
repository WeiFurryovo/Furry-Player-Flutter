//! furry-cli - 命令行工具
//!
//! 用于转换音频文件为 .furry 格式

use std::fs::File;
use std::io::Read;
use std::path::PathBuf;

use furry_converter::{pack_to_furry, unpack_from_furry, PackOptions, detect_format};
use furry_crypto::MasterKey;
use furry_format::FurryReader;

fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.len() < 3 {
        eprintln!("Usage:");
        eprintln!("  {} pack <input.mp3> <output.furry> [padding_kb]", args[0]);
        eprintln!("  {} unpack <input.furry> <output.mp3>", args[0]);
        eprintln!("  {} info <input.furry>   # prints JSON (valid/original_format)", args[0]);
        std::process::exit(1);
    }

    let command = &args[1];
    let master_key = MasterKey::default_key();

    match command.as_str() {
        "pack" => {
            if args.len() < 4 {
                eprintln!("Usage: {} pack <input> <output.furry> [padding_kb]", args[0]);
                std::process::exit(1);
            }

            let input_path = PathBuf::from(&args[2]);
            let output_path = PathBuf::from(&args[3]);
            let padding_kb: u64 = args.get(4).and_then(|s| s.parse().ok()).unwrap_or(0);

            let format = detect_format(&input_path);
            println!("Detected format: {:?}", format);

            let mut input = File::open(&input_path).expect("Failed to open input file");
            let mut output = File::create(&output_path).expect("Failed to create output file");

            let options = PackOptions {
                padding_bytes: padding_kb * 1024,
                ..Default::default()
            };

            pack_to_furry(&mut input, &mut output, format, &master_key, &options)
                .expect("Failed to pack");

            let input_size = std::fs::metadata(&input_path).unwrap().len();
            let output_size = std::fs::metadata(&output_path).unwrap().len();

            println!("Packed successfully!");
            println!("  Input:  {} bytes", input_size);
            println!("  Output: {} bytes", output_size);
            println!("  Ratio:  {:.2}x", output_size as f64 / input_size as f64);
        }
        "unpack" => {
            if args.len() < 4 {
                eprintln!("Usage: {} unpack <input.furry> <output>", args[0]);
                std::process::exit(1);
            }

            let input_path = PathBuf::from(&args[2]);
            let output_path = PathBuf::from(&args[3]);

            let mut input = File::open(&input_path).expect("Failed to open input file");
            let mut output = File::create(&output_path).expect("Failed to create output file");

            let format = unpack_from_furry(&mut input, &mut output, &master_key)
                .expect("Failed to unpack");

            println!("Unpacked successfully!");
            println!("  Original format: {:?}", format);
        }
        "info" => {
            let input_path = PathBuf::from(&args[2]);
            let file = match File::open(&input_path) {
                Ok(f) => f,
                Err(_) => {
                    println!(r#"{{"valid":false,"error":"open_failed"}}"#);
                    std::process::exit(2);
                }
            };

            // quick magic check first
            let mut reader = std::io::BufReader::new(file);
            let mut magic = [0u8; 8];
            if reader.read_exact(&mut magic).is_err() || &magic != b"FURRYFMT" {
                println!(r#"{{"valid":false,"error":"bad_magic"}}"#);
                std::process::exit(3);
            }

            // reopen for full parse (FurryReader expects start from 0)
            let file = match File::open(&input_path) {
                Ok(f) => f,
                Err(_) => {
                    println!(r#"{{"valid":false,"error":"open_failed"}}"#);
                    std::process::exit(2);
                }
            };

            let reader = match FurryReader::open(file, &master_key) {
                Ok(r) => r,
                Err(_) => {
                    println!(r#"{{"valid":false,"error":"parse_failed"}}"#);
                    std::process::exit(4);
                }
            };

            let ext = match reader.index.header.original_format {
                furry_format::OriginalFormat::Mp3 => "mp3",
                furry_format::OriginalFormat::Wav => "wav",
                furry_format::OriginalFormat::Ogg => "ogg",
                furry_format::OriginalFormat::Flac => "flac",
                furry_format::OriginalFormat::Unknown => "",
            };

            println!(r#"{{"valid":true,"original_format":"{}"}}"#, ext);
        }
        _ => {
            eprintln!("Unknown command: {}", command);
            std::process::exit(1);
        }
    }
}
