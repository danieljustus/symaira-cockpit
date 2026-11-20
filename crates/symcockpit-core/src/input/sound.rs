//! Procedural material sound: a few damped sine partials, rendered as a
//! 16-bit mono WAV. No audio files and no audio framework are needed to build
//! it; playing it is the adapter's job.

use serde::{Deserialize, Serialize};

const SAMPLE_RATE: u32 = 44_100;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Material {
    Wood,
    Glass,
    Metal,
    Rubber,
}

impl Material {
    pub fn parse(text: &str) -> Option<Material> {
        match text {
            "wood" => Some(Material::Wood),
            "glass" => Some(Material::Glass),
            "metal" => Some(Material::Metal),
            "rubber" => Some(Material::Rubber),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Material::Wood => "wood",
            Material::Glass => "glass",
            Material::Metal => "metal",
            Material::Rubber => "rubber",
        }
    }

    /// Partial frequencies in Hz and the decay time constant in milliseconds.
    fn voice(self) -> (&'static [f32], f32) {
        match self {
            Material::Wood => (&[420.0, 910.0], 35.0),
            Material::Glass => (&[2100.0, 3300.0, 5200.0], 90.0),
            Material::Metal => (&[880.0, 1760.0, 2490.0], 140.0),
            Material::Rubber => (&[180.0], 25.0),
        }
    }
}

/// Renders the click for `material` as a complete WAV file (RIFF, PCM, 16 bit, mono).
pub fn material_wav(material: Material) -> Vec<u8> {
    let (partials, decay_ms) = material.voice();
    let samples = (SAMPLE_RATE as f32 * decay_ms * 5.0 / 1000.0) as usize; // five time constants
    let tau = decay_ms / 1000.0;
    let mut pcm = Vec::with_capacity(samples * 2);
    for n in 0..samples {
        let t = n as f32 / SAMPLE_RATE as f32;
        let wave: f32 = partials
            .iter()
            .map(|f| (std::f32::consts::TAU * f * t).sin())
            .sum::<f32>()
            / partials.len() as f32;
        let value = (wave * (-t / tau).exp() * 0.6 * f32::from(i16::MAX)) as i16;
        pcm.extend_from_slice(&value.to_le_bytes());
    }
    let mut wav = Vec::with_capacity(44 + pcm.len());
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + pcm.len() as u32).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes()); // PCM
    wav.extend_from_slice(&1u16.to_le_bytes()); // mono
    wav.extend_from_slice(&SAMPLE_RATE.to_le_bytes());
    wav.extend_from_slice(&(SAMPLE_RATE * 2).to_le_bytes());
    wav.extend_from_slice(&2u16.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&(pcm.len() as u32).to_le_bytes());
    wav.extend_from_slice(&pcm);
    wav
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL: [Material; 4] = [
        Material::Wood,
        Material::Glass,
        Material::Metal,
        Material::Rubber,
    ];

    #[test]
    fn wav_header_matches_the_data() {
        for m in ALL {
            let w = material_wav(m);
            assert_eq!(&w[..4], b"RIFF");
            assert_eq!(&w[8..16], b"WAVEfmt ");
            let riff_len = u32::from_le_bytes(w[4..8].try_into().unwrap()) as usize;
            let data_len = u32::from_le_bytes(w[40..44].try_into().unwrap()) as usize;
            assert_eq!(riff_len, w.len() - 8);
            assert_eq!(data_len, w.len() - 44);
            assert!(data_len > 1000, "{m:?} is audible length");
        }
    }

    #[test]
    fn materials_sound_different_and_are_deterministic() {
        let sounds: Vec<_> = ALL.iter().map(|m| material_wav(*m)).collect();
        for i in 0..sounds.len() {
            assert_eq!(sounds[i], material_wav(ALL[i]));
            for j in i + 1..sounds.len() {
                assert_ne!(sounds[i], sounds[j]);
            }
        }
        // Not silence: some sample is far from zero.
        let w = &sounds[0];
        assert!(
            w[44..]
                .chunks(2)
                .any(|c| i16::from_le_bytes([c[0], c[1]]).abs() > 1000)
        );
    }

    #[test]
    fn names_round_trip() {
        for m in ALL {
            assert_eq!(Material::parse(m.name()), Some(m));
        }
        assert_eq!(Material::parse("stone"), None);
    }
}
