var map, photoLayer, tracksLayer;
var photoIndex, highlightInteraction;

var mapShown = false;
var infoShown = false;
var infoHidden = true;

// Check for Firefox, then set background manually.
var useImageSet = CSS.supports("( background-image: image-set(url('x') 1x) ) or ( background-image: -webkit-image-set(url('x') 1x) ) or ( background-image: -moz-image-set(url('x') 1x) ) or ( background-image: -ms-image-set(url('x') 1x) )");

// Common base layers
function baseLayers(default_layer) {
	var layers = [];

	layers.push(new ol.layer.Group({
		title: 'Base map',

		layers: [
			new ol.layer.Tile({
				title: 'Carto Dark',
				type: 'base',
				source: new ol.source.XYZ({
					url: 'https://cartodb-basemaps-a.global.ssl.fastly.net/dark_all/{z}/{x}/{y}.png'
				}),
				visible: ('Carto Dark' == default_layer) && ! window.devicePixelRatio > 1
			}),

			new ol.layer.Tile({
				title: 'Carto Dark 2×',
				type: 'base',
				source: new ol.source.XYZ({
					url: 'https://cartodb-basemaps-a.global.ssl.fastly.net/dark_all/{z}/{x}/{y}@2x.png',
					tilePixelRatio: 2,
				}),
				visible: ('Carto Dark' == default_layer) && window.devicePixelRatio > 1
			}),

			new ol.layer.Tile({
				title: 'OpenStreetMap',
				type: 'base',
				source: new ol.source.OSM(),
				visible: ('OpenStreetMap' == default_layer) && ! window.devicePixelRatio > 1
			}),

			new ol.layer.Tile({
				title: 'OpenStreetMap 2×',
				type: 'base',
				source: new ol.source.XYZ({
					url: 'https://a.osm.rrze.fau.de/osmhd/{z}/{x}/{y}.png',
					tilePixelRatio: 2,
				}),
				visible: ('OpenStreetMap' == default_layer) && window.devicePixelRatio > 1
			})

		]
	}));

	return layers;
}

// Load index page map.
function loadBigMap() {
	map = new ol.Map({
		layers: baseLayers('Carto Dark'),
		target: 'map',
		view: new ol.View()
	});
	$('#map').css("width",$('#mapcontainer').innerWidth());
	map.updateSize();

	var styleCache = {};
	var clusterStyle = function(feature) {
		var size = feature.get('features').length;
		var style = styleCache[size];
		if (!style) {
			style = new ol.style.Style({
				image: new ol.style.Circle({
					radius: 8,
					stroke: new ol.style.Stroke({
						color: '#000',
						width: 1
					}),
					fill: new ol.style.Fill({
						color: '#f0f'
					}),
					opacity: 0.5
				}),
				text: new ol.style.Text({
					text: size.toString(),
					fill: new ol.style.Fill({
						color: '#600'
					})
				})
			});
			styleCache[size] = style;
		}
		return style;
        }

	// Load and cluster photos
	var features = new ol.Collection();

	var source = new ol.source.Vector({
		features: features,
		useSpatialIndex: true
	});

	var clusterSource = new ol.source.Cluster({
		source: source
	});

	$.getJSON(".photos.json", function(data) {
		photoData = data.photos;
		photoIndex = {};
		$.each(data.photos, function(idx, p) {
			photoIndex[p.file] = p;
			if (p.point) {
				var feature = (new ol.Feature({
					geometry: new ol.geom.Point(ol.proj.fromLonLat(p.point)),
					labelPoint: new ol.geom.Point(p.title),
					file: p.file
				}));
				features.push(feature);
			}
		});
		if (features.getLength() == 0) {
			map.getView().setCenter([0,0]);
			map.getView().setZoom(2);
			return;
		}
		source.addFeatures(features);
		clusterSource.refresh();
		map.getView().fit(source.getExtent(), map.getSize());
		bindHighlightEvents(clusterSource);
	});

	photoLayer = new ol.layer.Vector({
		source: clusterSource,
		style: clusterStyle
	});

	// Loads tracks
	if (availableTracks.length > 0) {
		var trackColours = [[128,0,128,0.75], [0,255,255,0.75], [255,0,255,0.75]]; // Purple, cyan, magenta
		var tracks = [];
		for (i = 0; i < availableTracks.length; i++) {
			tracks[i] = new ol.layer.Vector({
				title: availableTracks[i],
				source: new ol.source.Vector({
					url: availableTracks[i],
					format: new ol.format.GPX()
				}),
				style: new ol.style.Style({
					stroke: new ol.style.Stroke({
						color: trackColours[i%trackColours.length],
						width: 5,
					})
				}),
			});
		}

		tracksLayer = new ol.layer.Group({
			title: 'Tracks',
			layers: tracks
		});
		map.addLayer(tracksLayer);
	}

	map.addLayer(photoLayer);

	highlightInteraction = new ol.interaction.Select({
		condition: ol.events.condition.click
	});

    map.addInteraction(highlightInteraction);
    highlightInteraction.on('select', highlight);

	var layerSwitcher = new ol.control.LayerSwitcher();
	map.addControl(layerSwitcher);
}

// Called by the map if there are geotagged photos
function bindHighlightEvents(clusterSource) {
	// Set up events to highlight cluster containing photos
	$('#files a').bind('mouseover', function() {
		// Select the cluster containing the photograph
		var find = $(this).attr("id");
		var point = photoIndex[find].point;
		var f = clusterSource.getClosestFeatureToCoordinate(ol.proj.fromLonLat(point));
		highlightInteraction.getFeatures().clear();
		highlightInteraction.getFeatures().push(f);
	});
	// And to un-unhighlight
	$('#files a').bind('mouseleave', function(event) {
		highlightInteraction.getFeatures().clear();
	});
}

// Toggle the display of the map
function toggleMap() {
	// Map is shown on top or right depending on screen size
	var mapClass;
	if ($(window).width() < $(window).height()) {
		mapClass = 'mapOnTop';
		$('#map').css("height",$(window).height()/3.0);
	}
	else {
		mapClass = 'mapOnRight';
		$('#map').css("height",$(window).height());
	}

	if (mapShown) {
		$('#mapcontainer').css("display","none");
		$('body').removeClass(mapClass);
	}
	else {
		$('#mapcontainer').css("display","block");
		$('#map').css("width",$('#mapcontainer').innerWidth());
		$('body').addClass(mapClass);
	}

	if (!map) {
		loadBigMap();
	}

	mapShown = !mapShown;
	put('mapShown', mapShown);

	tileNicely();
}

// Highlights all photos in the cluster.
function highlight(e) {
	var ids = [];
	if (e.selected.length > 0) {
		var cluster = e.target.getFeatures().item(0);
		ids = cluster.get('features').map((f) => f.get('file'));
	}

	var visible = false;
	$('#files a').each(function(idx) {
		var id = $(this).attr('id');
		if (ids.indexOf(id) !== -1) {
			$(this).removeClass('dimmed');
			visible = visible | isScrolledIntoView($(this));
		}
		else {
			$(this).addClass('dimmed');
		}
	});

	$('#files a').each(function(idx) {
		var id = $(this).attr('id');
		//if (isScrolledIntoView($(this))) {
		//	console.log("Picture "+$(this).attr('id')+" is fully visible");
		//}
	});

	if (!visible && e.selected.length > 0) {
		var to = $(jq(ids[0])).position().top;
		$('#files').animate({
			scrollTop: $('#files').scrollTop() + to
		}, 1000);
	}
}

// True if elem is visible in the browser window
function isScrolledIntoView(elem) {
	var scrTop = $('#files').scrollTop();
	var scrBottom = scrTop + $('#files').height();

	var elemTop = $(elem).position().top;
	var elemBottom = elemTop + $(elem).height();

	console.log(elem.attr('id'), scrTop, scrBottom, elemTop, elemBottom, elemTop >= 0, scrTop+elemTop <= scrBottom + 5, scrTop+elemBottom, '<', scrBottom+5, scrTop+elemBottom <= scrBottom + 5);

	return (elemTop >= 0) && (scrTop+elemTop <= scrBottom + 5) && (scrTop+elemBottom <= scrBottom + 5);
}

// Display a small map on the photo page's info area.
// Initialise the map, and display it.
function smallMap() {
	if (!('llat' in window && 'llong' in window)) {
		return;
	}

	// Define mark
	var point = new ol.geom.Point(ol.proj.fromLonLat([parseFloat(llong), parseFloat(llat)]));

	map = new ol.Map({
		layers: baseLayers('OpenStreetMap'),
		target: 'map',
		view: new ol.View({
			center: point.getCoordinates(),
			zoom: 15
		})
	});

	// Define mark style
	var pointStyle = new ol.style.Style({
		image: new ol.style.Circle({
			fill: new ol.style.Fill({color: '#f0f'}),
			stroke: new ol.style.Stroke({color: '#000', width: 1.5}),
			radius: 6,
			opacity: 0.8
		}),
	});

	photoLayer = new ol.layer.Vector({
		source: new ol.source.Vector({
			features: [new ol.Feature(point)]
		}),
		style: pointStyle
	});
	map.addLayer(photoLayer);

	var layerSwitcher = new ol.control.LayerSwitcher();
	map.addControl(layerSwitcher);

	map.updateSize();
}

// Escapes an id containing special characters (e.g. 001.jpg -> #001\\.jpg)
function jq(myid) {
	return '#' + myid.replace(/(:|\.)/g,'\\$1');
}

// Adjust the width parameter of the 'next' and 'previous' links according to the screen size.
function adjustPhotoWidths() {
	if (availablePhotoWidths.length == 0 || (document.getElementById('next') == null && document.getElementById('prev') == null)) {
		return;
	}

	var h = $(window).height() * window.devicePixelRatio;
	var w = $(window).width() * window.devicePixelRatio;

	// Choose the largest width that's not larger than the screen.
	var picw = availablePhotoWidths[availablePhotoWidths.length-1];

	for (var i = availablePhotoWidths.length - 1; i >= 0; i--) {
		if (w > availablePhotoWidths[i]) {
			break;
		}
		picw = availablePhotoWidths[i];
	}

	if (document.getElementById('next') != null) {
		var oldNextLink = $('#next').prop('href');
		var newNextLink = oldNextLink.replace(/width=\d+/, 'width='+picw);
		$('#next').prop('href', newNextLink);
		if (document.getElementById('refresh') != null) {
			var oldRefreshLink = $('#refresh').prop('content');
			var newRefreshLink = oldRefreshLink.replace(/width=\d+/, 'width='+picw);
			$('#refresh').prop('content', newRefreshLink);
		}
	}

	if (document.getElementById('prev') != null) {
		var oldPrevLink = $('#prev').prop('href');
		var newPrevLink = oldPrevLink.replace(/width=\d+/, 'width='+picw);
		$('#prev').prop('href', newPrevLink);
	}

	$("#size").hide();
}

function extractNumericAttribute(elem, attribute) {
	var w = parseInt($(elem).attr(attribute));
	if (w > 0) {
		return w;
	}
	else {
		return 80;
	}
}

// Adjust photo widths and heights to tile nicely across the screen.
function tileNicely() {
	if (document.getElementById('files') == null) {
		return;
	}

	// Target width and height
	var h_s = $(window).height() - 4;
	var w_s = $("#files").width() - 4;

	// Target number of rows shown
	var rows = 2.8;

	// Aim for rows rows of photos of width w_aim and height h_aim
	// h_aim = w_aim/1.5 (assumed ratio of landscape photo)
	// h_s = rows * h_aim = rows * w_aim/1.5
	var h_aim = h_s / rows;
	var w_aim = h_s * 1.5 / rows;

	// How many photos fit in the screen width?
	// On devices with ≤800px width, display maximum two images per row.
	var n = Math.round(w_s / w_aim);
	if (n < 2 || w_s < 800) n = 2;

	// Minimum total width, allowing for some scaling up, is thus
	var wt_min = (n-1) * w_aim + 0.5*w_aim;

	// Load photo sizes (supplied in HTML)
	var p_photos = $("#files a");
	var w_photos = $("#files a").map( function() {
		return extractNumericAttribute(this, 'data-width');
	}).get();
	var h_photos = $("#files a").map( function() {
		return extractNumericAttribute(this, 'data-height');
	}).get();

	// Next row
	var w_row = [];
	var h_row = [];

	var i = 0;
	var j = 0;

	var p = 0;
	while (i < w_photos.length) {
		// So pick photos until ∑w > wt_min.
		w_row[w_row.length] = w_photos[i];
		h_row[h_row.length] = h_photos[i];

		// Sum widths in current row
		w_row_total = 0;
		for (j = 0; j < w_row.length; j++) {
			w_row_total += w_row[j] * h_aim / h_row[j];
		}

		var lastRow = (i + 1 == w_photos.length);

		// We have a row to process
		if (w_row_total > wt_min || lastRow) {
			// Scale the photos
			for (j = 0; j < w_row.length; j++) {
				var factor = h_aim / h_row[j];
				h_row[j] = h_aim;
				w_row[j] = w_row[j] * factor;
			}

			w_row_total = 0;
			for (j = 0; j < w_row.length; j++) {
				w_row_total += w_row[j];
			}

			if (lastRow && w_row_total / w_s < 0.66) {
				w_row_total = w_s;
			}

			// Scale to screen width
			var w_factor = (w_s - (10 * (w_row.length - 1))) / w_row_total;
			for (j = 0; j < w_row.length; j++) {
				h_row[j] = h_row[j] * w_factor;
				w_row[j] = w_row[j] * w_factor;

				var elem = $(p_photos.get(p));

				// Set dimensions
				elem.width(w_row[j]);
				elem.height(h_row[j]);

				// Calculate change to dimensions in provided image URL
				var img_url = elem.attr("data-img");

				// Round to nearest 100 to reduce number of sizes generated by the server
				var new_width = Math.ceil(w_row[j]/100)*100;
				var new_img_url = [];
				var resized = false;
				if (img_url.match(/.bg-\d+/)) {
					new_img_url[1] = img_url.replace(/.bg-\d+/, '.bg-'+(1*new_width));
					new_img_url[2] = img_url.replace(/.bg-\d+/, '.bg-'+(2*new_width));
					new_img_url[3] = img_url.replace(/.bg-\d+/, '.bg-'+(3*new_width));
					resized = true;
				}
				else if (img_url.match(/w=\d+/)) {
					new_img_url[1] = img_url.replace(/w=\d+/, 'w='+(1*new_width)).replace(/h=\d+/, 'h='+  Math.round(h_row[j]*new_width/w_row[j]));
					new_img_url[2] = img_url.replace(/w=\d+/, 'w='+(2*new_width)).replace(/h=\d+/, 'h='+2*Math.round(h_row[j]*new_width/w_row[j]));
					new_img_url[3] = img_url.replace(/w=\d+/, 'w='+(3*new_width)).replace(/h=\d+/, 'h='+3*Math.round(h_row[j]*new_width/w_row[j]));
					resized = true;
				}

				if (resized) {
					// Set style
					var old_style = elem.attr('style'),
					    new_style;

					if (useImageSet) {
						new_style = old_style + "; " +
							"background-image: url('" + new_img_url[1] + "'), url('/ApacheGallery/modern/squares.gif'); " +
							"background-image: image-set(url(" + new_img_url[1] + ") 1x, url(" + new_img_url[2] + ") 2x, url(" + new_img_url[3] + ") 3x), url('/ApacheGallery/modern/squares.gif');" +
							"background-image: -webkit-image-set(url(" + new_img_url[1] + ") 1x, url(" + new_img_url[2] + ") 2x, url(" + new_img_url[3] + ") 3x), url('/ApacheGallery/modern/squares.gif');" +
							"background-image: -moz-image-set(url(" + new_img_url[1] + ") 1x, url(" + new_img_url[2] + ") 2x, url(" + new_img_url[3] + ") 3x), url('/ApacheGallery/modern/squares.gif');" +
							"background-image: -ms-image-set(url(" + new_img_url[1] + ") 1x, url(" + new_img_url[2] + ") 2x, url(" + new_img_url[3] + ") 3x), url('/ApacheGallery/modern/squares.gif');";
					}
					else {
						var dpr = Math.min(3, Math.ceil(window.devicePixelRatio));

						new_style = old_style + "; " +
							"background-image: url('" + new_img_url[dpr] + "'), url('/ApacheGallery/modern/squares.gif');" +
							"background-size: 100%;";
					}

					elem.attr('style', new_style);

					// Event to remove SVG spinner once image is loaded, as it uses a lot of CPU even when obscured.
					// Difficult to implement with the HiDPI images, so the SVG has been replaced with a GIF.
					//$('<img/>').attr('src', new_1ximg_url).data('target', elem).load(function() {
					//	$(this).data('target').css('background-image', "url('"+$(this).attr('src')+"')");
					//	$(this).remove();
					//});
				}

				// Change CSS rule since the sizes are different.
				var elemSpan = elem.children('span').first();
				elemSpan.css("margin", "0");
				elemSpan.css("transform", "translateX("+(w_row[j]/2)+"px) translateX(-50%) translateY("+(h_row[j]/2)+"px) translateY(-50%) rotate("+(Math.random()*0.1-0.05)+"rad)");

				p++;
			}

			// Start a new row
			w_row = [];
			h_row = [];
		}
		i++;
	}
}

// Creates a button to allow the user to show the large map.
// (First function called)
function createToggleMapButton() {
	$('#mapcontainer').css("display","none");
	$('#mapcontainer').css("visibility","visible");

	// Set up the 'toggle map' button
	var hide = $('#menu').append('<div id="menuButtons"><a id="toggleMap">&#x1f30d;</a></div>');
	$('#toggleMap').bind('click', toggleMap);
}

// Creates a button to allow the user to toggle the photo information.
// (First function called)
function createToggleInfoButton() {
	// Set up the 'toggle info' button
	var hide = $('#menuButtons').append('<ul id="toggleInfo"><li>&#x1f4f7;</li></ul>');
	$('#toggleInfo').bind('click', toggleInfo);
}

// Toggle the display of the photo information
function toggleInfo() {
	if (document.getElementById('info') == null) {
		return;
	}

	// Info is shown on the right
	var infoClass;
	infoClass = 'infoOnRight';

	if (infoShown) {
		$('body').removeClass(infoClass);
	}
	else {
		$('body').addClass(infoClass);
		$('#map').width($('#info').width());
		$('#map').height(300);
	}

	if (!map) {
		smallMap();
	}

	infoShown = !infoShown;
	put('infoShown', infoShown);

	if (map) {
		map.updateSize();
	}
}

var get = function (key) {
	return window.localStorage ? window.localStorage[key] : null;
}

var put = function (key, value) {
	if (window.localStorage) {
		window.localStorage[key] = value;
	}
}

$(window).resize(function() {
	adjustPhotoWidths();
	tileNicely();
	if (mapShown) {
		$('#map').css("width",$('#map').parent().innerWidth());
		map.updateSize();
	}
});

$(document).ready(function() {
	adjustPhotoWidths();
	tileNicely();

	if ('hasInfo' in window) {
		createToggleInfoButton();
		if (get('infoShown') == 'true') {
			toggleInfo();
		}
	}

	if ('hasMap' in window) {
		createToggleMapButton();
		if (get('mapShown') == 'true') {
			toggleMap();
		}
	}
});
