// place-map: MapKit on iOS, made for this app (LLP 1024 D4). The package
// `@exact/maps` draws a map too, but it reports no gesture's coordinate; a
// long press here is the app's way to the sheet.
//
// props   latitude, longitude, zoomLevel   the camera the app asks for
//         markers   a JSON list of {id, latitude, longitude, title, photo}
//         pending   "lat, lon" of a long press, drawn as a pin until it is saved
// events  change    the map's centre, when a gesture ends
//         message   "lat, lon" of a long press
import Foundation
import MapKit
import UIKit

final class PlaceMapModule: ExactModule {
    override class var views: [String: ExactNativeFactory] {
        ["place-map": ExactNativeFactory(for: PlaceMapModule.self) { module, props, events in
            try PlaceMap(files: module.context, props: props, events: events)
        }]
    }
}
let exactModule: ExactModule.Type = PlaceMapModule.self

/// A saved place's pin; the app's markers are MapKit's own.
final class PlaceMarker: MKPointAnnotation {
    let id: String
    let photo: String?
    init(id: String, title: String?, photo: String?, coordinate: CLLocationCoordinate2D) {
        self.id = id
        self.photo = photo
        super.init()
        self.title = title
        self.coordinate = coordinate
    }
}

/// The map, with a layout callback: a camera asked for before the map had a
/// size is placed once it does.
final class PlaceMapView: MKMapView {
    var laidOut: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        laidOut?()
    }
}

/// MapKit's delegate, and the long press. An `ExactNativeInstance` is no
/// `NSObject`, so the delegates it needs live here.
final class PlaceMapGestures: NSObject, MKMapViewDelegate {
    var moved: ((CLLocationCoordinate2D) -> Void)?
    var pressed: ((CLLocationCoordinate2D) -> Void)?
    var files: ExactModuleContext?

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        moved?(mapView.centerCoordinate)
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard annotation is PlaceMarker else { return nil }
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: "place") as? MKMarkerAnnotationView
            ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "place")
        view.annotation = annotation
        view.canShowCallout = true
        view.leftCalloutAccessoryView = (annotation as? PlaceMarker).flatMap { marker in
            photoImage(marker.photo).map { image -> UIImageView in
                let thumb = UIImageView(image: image)
                thumb.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
                thumb.contentMode = .scaleAspectFill
                thumb.clipsToBounds = true
                thumb.layer.cornerRadius = 6
                return thumb
            }
        }
        return view
    }

    /// The saved place's photo, in the app's own files.
    private func photoImage(_ path: String?) -> UIImage? {
        guard let files, let path, path.hasPrefix("app:/") else { return nil }
        let parts = path.dropFirst(5).split(separator: "/", maxSplits: 1).map(String.init)
        let roots = ["data": files.data, "cache": files.cache, "tmp": files.temporary]
        guard parts.count == 2, let root = roots[parts[0]] else { return nil }
        return UIImage(contentsOfFile: root.appendingPathComponent(parts[1]).path)
    }

    @objc func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let map = recognizer.view as? MKMapView else { return }
        pressed?(map.convert(recognizer.location(in: map), toCoordinateFrom: map))
    }
}

final class PlaceMap: ExactNativeInstance {
    private let map = PlaceMapView(frame: .zero)
    private let gestures = PlaceMapGestures()
    private var props: [String: String] = [:]
    private var first = true
    private var asked: (CLLocationCoordinate2D, Double)?
    private var fitPending: [MKAnnotation] = []
    private var draft: MKPointAnnotation?

    init(files: ExactModuleContext, props: [String: String], events: ExactNativeEvents) throws {
        super.init(events: events)
        map.delegate = gestures
        gestures.files = files
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "place")
        gestures.moved = { [weak self] centre in self?.events.change(Self.text(centre)) }
        gestures.pressed = { [weak self] centre in self?.events.message(Self.text(centre)) }
        map.laidOut = { [weak self] in
            self?.place()
            self?.fit()
        }
        let press = UILongPressGestureRecognizer(target: gestures, action: #selector(PlaceMapGestures.longPressed(_:)))
        press.minimumPressDuration = 0.45
        map.addGestureRecognizer(press)
        try setProps(props)
    }

    override var view: ExactNativeView { map }

    override func setProps(_ props: [String: String]) throws {
        let asked = props["latitude"] != self.props["latitude"]
            || props["longitude"] != self.props["longitude"]
            || props["zoomLevel"] != self.props["zoomLevel"]
        if let lat = Double(props["latitude"] ?? ""), let lon = Double(props["longitude"] ?? ""), first || asked {
            let centre = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            self.asked = (centre, Double(props["zoomLevel"] ?? "") ?? 12)
            place()
        }
        if first || props["markers"] != self.props["markers"] {
            markers(props["markers"] ?? "", fitting: latIsZero(props))
        }
        if first || props["pending"] != self.props["pending"] {
            pin(props["pending"] ?? "")
        }
        map.showsUserLocation = props["userLocation"] == "true"
        if let label = props["aria-label"] {
            map.accessibilityLabel = label
        }
        self.props = props
        first = false
    }

    /// A camera asked for before the map had a size is placed once it does.
    private func place() {
        guard let (centre, zoom) = asked, map.bounds.width > 0, map.bounds.height > 0 else { return }
        asked = nil
        let span = 360.0 / pow(2.0, zoom)
        map.setRegion(MKCoordinateRegion(center: centre, span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)), animated: !first)
    }

    private func markers(_ json: String, fitting: Bool) {
        map.removeAnnotations(map.annotations.filter { $0 is PlaceMarker })
        guard let data = json.data(using: .utf8),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        let saved = rows.compactMap { row -> PlaceMarker? in
            guard let id = row["id"] as? String, let lat = row["latitude"] as? Double, let lon = row["longitude"] as? Double else { return nil }
            let title = (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let photo = (row["photo"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return PlaceMarker(id: id, title: title, photo: photo, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        map.addAnnotations(saved)
        if fitting, !saved.isEmpty {
            fitPending = saved
            self.fit()
        }
    }

    /// The saved places, once the map has a size: the camera's own when the
    /// app asked for none.
    private func fit() {
        guard !fitPending.isEmpty, map.bounds.width > 0, map.bounds.height > 0 else { return }
        let saved = fitPending.map { $0.coordinate }
        fitPending = []
        guard let first = saved.first else { return }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in saved {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let centre = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = max(max(maxLat - minLat, maxLon - minLon) * 1.6, 0.01)
        map.setRegion(MKCoordinateRegion(center: centre, span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)), animated: false)
    }

    private func pin(_ text: String) {
        if let draft {
            map.removeAnnotation(draft)
            self.draft = nil
        }
        guard let centre = Self.point(text) else { return }
        let pin = MKPointAnnotation()
        pin.coordinate = centre
        pin.title = "New place"
        map.addAnnotation(pin)
        draft = pin
    }

    private func latIsZero(_ props: [String: String]) -> Bool {
        Double(props["latitude"] ?? "") == 0 && Double(props["longitude"] ?? "") == 0
    }

    private static func point(_ text: String) -> CLLocationCoordinate2D? {
        let parts = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let lat = parts[0], let lon = parts[1], abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private static func text(_ centre: CLLocationCoordinate2D) -> String {
        let lat = abs(centre.latitude) < 0.0000005 ? 0 : centre.latitude
        let lon = abs(centre.longitude) < 0.0000005 ? 0 : centre.longitude
        return String(format: "%.6f, %.6f", lat, lon)
    }
}
