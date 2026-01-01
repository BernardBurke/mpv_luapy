import sys
import os
import xml.etree.ElementTree as ET
from xml.dom import minidom

def parse_edl_line(line):
    """
    Parses a line in the mpv EDL format: 
    /full/path/to/video.mp4, start, length
    """
    line = line.strip()
    # Skip comments or empty lines
    if not line or line.startswith('#'):
        return None

    try:
        # Split from the right to handle filenames containing commas.
        # We need exactly 3 parts: Path, Start, Length
        parts = line.rsplit(',', 2)
        
        if len(parts) != 3:
            # Fallback for space-separated legacy formats if commas aren't found
            parts = line.split()
            if len(parts) < 3: return None
            
            # Re-assemble path if it contained spaces
            path = " ".join(parts[:-2])
            start = float(parts[-2])
            length = float(parts[-1])
        else:
            path = parts[0].strip()
            start = float(parts[1])
            length = float(parts[2])

        return {
            'path': path,
            'start': start,
            'length': length
        }
    except ValueError:
        print(f"[Warn] Skipping invalid line format: {line}")
        return None

def create_kdenlive_project(edl_path, output_path):
    # 1. Initialize MLT XML Root
    # We leave the profile generic so Kdenlive asks to auto-adjust on load.
    root = ET.Element("mlt")
    root.set("version", "7.0")
    root.set("title", "EDL Import")
    root.set("producer", "maintractor") # Point to the main timeline tractor

    # 2. Parse EDL
    cuts = []
    unique_paths = {} 
    producer_counter = 0

    print(f"Reading EDL: {edl_path}")
    try:
        with open(edl_path, 'r', encoding='utf-8') as f:
            for line in f:
                data = parse_edl_line(line)
                if data:
                    cuts.append(data)
                    if data['path'] not in unique_paths:
                        unique_paths[data['path']] = f"producer{producer_counter}"
                        producer_counter += 1
    except FileNotFoundError:
        print("Error: EDL file not found.")
        return

    if not cuts:
        print("Error: No valid cuts found in EDL.")
        return

    # 3. Create Producers (The Source Files)
    print(f"Found {len(unique_paths)} unique source files.")
    for path, pid in unique_paths.items():
        producer = ET.SubElement(root, "producer")
        producer.set("id", pid)
        
        # 'resource' tells Kdenlive where the file is
        prop = ET.SubElement(producer, "property")
        prop.set("name", "resource")
        prop.text = path
        
        # 'force_aspect_ratio' property can be added here if needed, 
        # but leaving it out lets Kdenlive detect it.

    # 4. Create the Playlist (The Virtual Timeline)
    playlist = ET.SubElement(root, "playlist")
    playlist.set("id", "playlist0")

    print(f"Processing {len(cuts)} cuts...")
    for cut in cuts:
        pid = unique_paths[cut['path']]
        
        # Calculate In/Out points (Seconds)
        start_sec = cut['start']
        length_sec = cut['length']
        end_sec = start_sec + length_sec

        entry = ET.SubElement(playlist, "entry")
        entry.set("producer", pid)
        entry.set("in", f"{start_sec:.3f}")
        entry.set("out", f"{end_sec:.3f}")

    # 5. Create Tractor (The Track Layout)
    # A tractor combines playlists into tracks.
    tractor = ET.SubElement(root, "tractor")
    tractor.set("id", "maintractor")
    
    # We define one video track that contains our playlist
    track = ET.SubElement(tractor, "track")
    track.set("producer", "playlist0")
    
    # Optional: Add a second track definition if you wanted audio separation,
    # but for a rough cut, a single AV track is best.

    # 6. Write the File
    # We use minidom to make the XML human-readable (pretty print)
    xml_str = minidom.parseString(ET.tostring(root)).toprettyxml(indent="  ")
    
    try:
        with open(output_path, "w", encoding='utf-8') as f:
            f.write(xml_str)
        print(f"Success! Project saved to: {output_path}")
    except IOError as e:
        print(f"Error writing output file: {e}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python edl2kdenlive.py <edl_file> [output_file]")
        sys.exit(1)

    edl_file = sys.argv[1]
    
    if len(sys.argv) > 2:
        out_file = sys.argv[2]
    else:
        # Default: replace .edl extension with .kdenlive
        base = os.path.splitext(edl_file)[0]
        out_file = base + ".kdenlive"

    create_kdenlive_project(edl_file, out_file)