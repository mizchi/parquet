use std::fs;
use std::hint::black_box;
use std::time::{Duration, Instant};

use bytes::Bytes;
use parquet::arrow::arrow_reader::ParquetRecordBatchReaderBuilder;

struct Case {
    name: &'static str,
    path: &'static str,
}

const CASES: &[Case] = &[
    Case {
        name: "read delta binary packed benchmark",
        path: "fixtures/apache-parquet-testing/data/delta_binary_packed.parquet",
    },
    Case {
        name: "read int32 null pages benchmark",
        path: "fixtures/apache-parquet-testing/data/int32_with_null_pages.parquet",
    },
    Case {
        name: "read fixed length byte array benchmark",
        path: "fixtures/apache-parquet-testing/data/fixed_length_byte_array.parquet",
    },
    Case {
        name: "read alltypes plain benchmark",
        path: "fixtures/apache-parquet-testing/data/alltypes_plain.parquet",
    },
    Case {
        name: "read alltypes dictionary benchmark",
        path: "fixtures/apache-parquet-testing/data/alltypes_dictionary.parquet",
    },
    Case {
        name: "read int96 from spark benchmark",
        path: "fixtures/apache-parquet-testing/data/int96_from_spark.parquet",
    },
    Case {
        name: "read empty snappy datapage v2 benchmark",
        path: "fixtures/apache-parquet-testing/data/datapage_v2_empty_datapage.snappy.parquet",
    },
];

fn materialize_rows(data: Bytes) -> parquet::errors::Result<usize> {
    let builder = ParquetRecordBatchReaderBuilder::try_new(data)?;
    let mut reader = builder.with_batch_size(1024).build()?;
    let mut rows = 0usize;
    for batch in &mut reader {
        let batch = batch?;
        rows += batch.num_rows();
        black_box(batch);
    }
    Ok(rows)
}

fn benchmark_case(case: &Case) -> Result<f64, Box<dyn std::error::Error>> {
    let data = Bytes::from(fs::read(case.path)?);
    for _ in 0..5 {
        black_box(materialize_rows(data.clone())?);
    }
    let mut samples = Vec::new();
    let mut total = Duration::ZERO;
    while samples.len() < 20 || total < Duration::from_millis(500) {
        let start = Instant::now();
        black_box(materialize_rows(data.clone())?);
        let elapsed = start.elapsed();
        total += elapsed;
        samples.push(elapsed.as_secs_f64() * 1_000_000.0);
        if samples.len() >= 200 {
            break;
        }
    }
    let mean = samples.iter().sum::<f64>() / samples.len() as f64;
    Ok(mean)
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    for case in CASES {
        match benchmark_case(case) {
            Ok(mean_us) => println!("{}\tok\t{mean_us:.3}", case.name),
            Err(err) => println!("{}\terr\t{err}", case.name),
        }
    }
    Ok(())
}
