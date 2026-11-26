import type { Answer, Result, Sources, Storage } from './app.contract.d.ts';

export const grants = `device.camera purpose.camera
device.geolocation purpose.location
fs.read app:/data
fs.write app:/data`;

type Place = Result<'loadPlaces'>[number];
const DIR = 'app:/data';
const FILE = `${DIR}/places.json`;

const load = (storage: Storage): Promise<Place[]> =>
  storage.fs.readFile(FILE).then(
    (bytes) => JSON.parse(new TextDecoder().decode(bytes)),
    (e) => {
      if (e.code === 'ENOENT') return [];
      throw e;
    });

const write = (storage: Storage, places: Place[]) =>
  storage.fs.atomicWriteFile(FILE, new TextEncoder().encode(JSON.stringify(places)));

const point = (at: string): { latitude: number; longitude: number } => {
  const [latitude, longitude] = at.split(',').map((v) => Number(v.trim()));
  return { latitude, longitude };
};

const nextId = (places: Place[]): string =>
  String(places.reduce((max, p) => Math.max(max, Number(p.id)), 0) + 1);

const sources: Sources = {
  loadPlaces: (_args, _store, storage) => load(storage),
  markerJson: async (_args, _store, storage) => ({
    json: JSON.stringify(
      (await load(storage)).map((p) => ({ id: p.id, latitude: p.latitude, longitude: p.longitude, title: p.label, photo: p.photo })),
    ),
  }),
  savePlace: async ([at, label, photo], _store, storage) => {
    const all = await load(storage);
    const id = nextId(all);
    let kept = '';
    if (photo != '') {
      const dot = photo.lastIndexOf('.');
      kept = `${DIR}/photos/${id}${dot >= 0 ? photo.slice(dot) : '.jpg'}`;
      await storage.fs.atomicWriteFile(kept, await storage.fs.readFile(photo));
    }
    await write(storage, [...all, { id, ...point(at), label, photo: kept }]);
    return { id };
  },
};

export const answer: Answer = (source, args, store, storage, native) =>
  sources[source](args, store, storage, native);
