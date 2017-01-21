var map, template, photos, select, tracks;

var mapInitialised = false;
var mapHidden = true;
var infoHidden = true;

OpenLayers.ImgPath = "/ApacheGallery/";

// Initialise index page map.
function initialiseBigMap() {
	map = new OpenLayers.Map();
	map.addControl(new OpenLayers.Control.LayerSwitcher());

	// Load base maps
	var base = new OpenLayers.Layer.OSM(
		"OpenStreetMap",
		// Official OSM tileset as protocol-independent URLs
		[
			'//a.tile.openstreetmap.org/${z}/${x}/${y}.png',
			'//b.tile.openstreetmap.org/${z}/${x}/${y}.png',
			'//c.tile.openstreetmap.org/${z}/${x}/${y}.png'
		],
		null);
	var ghyb = new OpenLayers.Layer.Google(
		"Google Hybrid",
		{type: google.maps.MapTypeId.HYBRID, numZoomLevels: 20}
	);
	var gsat = new OpenLayers.Layer.Google(
		"Google Satellite",
		{type: google.maps.MapTypeId.SATELLITE, numZoomLevels: 22}
	);

	// Define marker style
	var style = new OpenLayers.Style({
		pointRadius: "${radius}",
		fillColor: "#ff00ff",
		fillOpacity: 0.8,
		strokeColor: "#000000",
		strokeWidth: 2,
		strokeOpacity: 0.8
	}, {
		context: {
			radius: function(feature) {
				return Math.min(feature.attributes.count, 7) + 3;
			}
		}
	});

	// Load photos
	photos = new OpenLayers.Layer.Vector("Photos", {
		strategies: [
			new OpenLayers.Strategy.Fixed(),
			new OpenLayers.Strategy.Cluster()
		],
		protocol: new OpenLayers.Protocol.HTTP({
			url: ".points.xml",
			format: new OpenLayers.Format.GML()
		}),
		styleMap: new OpenLayers.StyleMap({
			"default": style,
			"select": {
				fillColor: "#00ffff",
				strokeColor: "#0000ff"
			}
		})
	});
	photos.events.register('loadend', photos, photosLoaded);

	// Loads tracks
	trackColours = ['purple', 'cyan', 'magenta'];
	tracks = [];
	for (i = 0; i < availableTracks.length; i++) {
		tracks[i] = new OpenLayers.Layer.Vector(availableTracks[i], {
			strategies: [new OpenLayers.Strategy.Fixed()],
			protocol: new OpenLayers.Protocol.HTTP({
				url: availableTracks[i],
				format: new OpenLayers.Format.GPX()
			}),
			style: {
				strokeColor: trackColours[i%trackColours.length],
				strokeWidth: 5,
				strokeOpacity: 0.75
			},
			projection: new OpenLayers.Projection("EPSG:4326")
		});
		console.log(i+"th track: "+availableTracks[i]);
		console.log(tracks[i]);
	}

	// Add layers to map
	map.addLayers([base, photos, ghyb, gsat]);
	map.addLayers(tracks);

	// Define select (hover) on markers behaviour
	select = new OpenLayers.Control.SelectFeature(
		photos, {hover: true}
	);
	map.addControl(select);
	select.activate();
	photos.events.on({"featureselected": highlight});
}

// Undims all photos
function undimAll() {
	$('#files a').removeClass("dimmed");
	for (i = 0; i < photos.features.length; i++) {
		var feature = photos.features[i];
		select.unselect(feature);
	}
}

// Called when photos have loaded (seems to be called after a single photo is loaded)
function photosLoaded(event) {
	if (photos.features.length > 0) {
		console.log("At least "+photos.features.length+" photos");
		initMapElements();

		// No idea why it's necessary to call this twice.  Calling once centres on the first cluster,
		// called a second time all the other clusters are shown too.
		map.zoomToExtent(event.object.getDataExtent());
		map.zoomToExtent(event.object.getDataExtent());
	}
	else {
		console.log("No photos");
	}
}

// Called by the map if there are geotagged photos
function initMapElements() {
	// Put the map in its div
	$('#map').css("display","block");
	map.render("map");

	// Set up events to highlight cluster contaning photos
	$('#files a').bind('mouseover', function() {
		var find = $(this).attr("id");
		//console.log("finding "+find);

		// Select the cluster containing the photograph
		for (i = 0; i < photos.features.length; i++) {
			var feature = photos.features[i];
			select.unselect(feature);
			for (j = 0; j < feature.cluster.length; j++) {
				var cluster = feature.cluster[j];
				//console.log("fid: "+cluster.fid);
				if (cluster.fid == find) {
					select.select(feature);
				}
			}
		}
	});
	// And to un-unhighlight
	$('#map').bind('mouseleave', function(event) {
		undimAll();
	});
	$('#files').bind('mouseleave', function(event) {
		undimAll();
	});

	// Set up events to zoom in to hovered thumbnails
	//$('#files a').bind('mouseover', function() {
	//	var find = $(this).attr("id");
	//});

	$('#map').css("width",$('#mapcontainer').innerWidth());
	map.updateSize();
}

// Creates a button to allow the user to show the large map.
// (First function called)
function createToggleMapButton() {

	$('#map').css("display","none");
	$('#mapcontainer').css("display","block");
	$('#mapcontainer').css("visibility","visible");

	// Set up the 'toggle map' button
	var hide = $('#menu').append('<div id="menuButtons"><a id="toggleMap">&#x1f30d;</a></div>');
	$('#toggleMap').bind('click', toggleMap);
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

	if (!mapInitialised) {
		mapHidden = false;
		initialiseBigMap();
		$('#directory').addClass(mapClass);
	}

	if (mapInitialised) {
		mapHidden = !mapHidden;
		if (!mapHidden) {
			$('#map').css("display","block");
			$('#directory').addClass(mapClass);
		}
		else {
			$('#map').css("display","none");
			$('#directory').removeClass(mapClass);
		}
		undimAll();
	}

	tileNicely();

	mapInitialised = true;
}

// Highlights all photos in the cluster.
function highlight(event) {
	// Dim all photos
	$('#files a').addClass("2bdimmed");
	// Un-highlight all photos
	//$('#files a').fadeTo('fast', 0.333);

	// Undim ones in the cluster
	visible = false;
	for (var i = 0; i < event.feature.cluster.length; i++) {
		var fileId = event.feature.cluster[i].attributes.file;
		$(jq(fileId)).removeClass("2bdimmed");
		//$(jq(fileId)).fadeTo('fast', 1);
		visible = visible | isScrolledIntoView($(jq(fileId)));
	}

	// If none of the photos in the cluster are visible scroll to the first.
	var idstring = String(event.feature.cluster[0].attributes.file);
	if (!visible) {
		$('html, body').animate({
			scrollTop: $(jq(idstring)).offset().top - $('#menu').height() - 20
		}, 1000);
	}

	$('#files a.2bdimmed').addClass("dimmed");
	$('#files a:not(a.2bdimmed)').removeClass("dimmed");
	$('#files a').removeClass("2bdimmed");
}

// True if elem is visible in the browser window
function isScrolledIntoView(elem) {
	var scrTop = $(window).scrollTop();
	var scrBottom = scrTop + $(window).height();

	var elemTop = $(elem).offset().top;
	var elemBottom = elemTop + $(elem).height();

	return ((elemTop <= scrBottom) && (elemBottom >= scrTop));
}

// Display a small map on the photo page's info area.
// Initialise the map, and display it.
function smallmap(llat, llong, status) {
	map = new OpenLayers.Map('map', { controls: [] });
	map.addControl(new OpenLayers.Control.MouseToolbar());

	$('#map').width($('#info').width());
	$('#map').height(300);

	var base = new OpenLayers.Layer.OSM();
	map.addLayer(base);

	var lonlat = new OpenLayers.LonLat(llong, llat).transform(
		new OpenLayers.Projection("EPSG:4326"),
		map.getProjectionObject()
	)

	map.setCenter(lonlat, 15);

	// Define mark style
	var style = new OpenLayers.Style({
		pointRadius: "4",
		fillColor: "#ff00ff",
		fillOpacity: 0.8,
		strokeColor: "#000000",
		strokeWidth: 2,
		strokeOpacity: 0.8
	});

	// Add mark to map
	mark = new OpenLayers.Layer.Vector("Photo", {
		styleMap: new OpenLayers.StyleMap({ "default": style })
	});

	var point = new OpenLayers.Geometry.Point(llong, llat);
	var pointFeature = new OpenLayers.Feature.Vector(point.transform(
		new OpenLayers.Projection("EPSG:4326"),
		map.getProjectionObject()
	));

	mark.addFeatures(pointFeature);

	map.addLayer(mark);
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

	var h = $(window).height();
	var w = $(window).width();

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
	var h_s = $(window).height() - 40;
	var w_s = $("#files").width() - 40;

	// Target number of rows shown
	var rows = 2.8;

	// Aim for rows rows of photos of width w_aim and height h_aim
	// h_aim = w_aim/1.5 (assumed ratio of landscape photo)
	// h_s = rows * h_aim = rows * w_aim/1.5
	var h_aim = h_s / rows;
	var w_aim = h_s * 1.5 / rows;

	// How many photos fit in the screen width?
	var n = Math.round(w_s / w_aim);
	if (n < 2) n = 2;

	// Minimum total width, allowing for some scaling up, is thus
	var wt_min = n * w_aim;

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
				var new_1ximg_url, new_2ximg_url, new_3ximg_url;
				if (img_url.match(/.bg-\d+/)) {
					new_1ximg_url = img_url.replace(/.bg-\d+/, '.bg-'+(1*new_width));
					new_2ximg_url = img_url.replace(/.bg-\d+/, '.bg-'+(2*new_width));
					new_3ximg_url = img_url.replace(/.bg-\d+/, '.bg-'+(3*new_width));
					resized = true;
				}
				else if (img_url.match(/w=\d+/)) {
					new_1ximg_url = img_url.replace(/w=\d+/, 'w='+(1*new_width)).replace(/h=\d+/, 'h='+  Math.round(h_row[j]*new_width/w_row[j]));
					new_2ximg_url = img_url.replace(/w=\d+/, 'w='+(2*new_width)).replace(/h=\d+/, 'h='+2*Math.round(h_row[j]*new_width/w_row[j]));
					new_3ximg_url = img_url.replace(/w=\d+/, 'w='+(3*new_width)).replace(/h=\d+/, 'h='+3*Math.round(h_row[j]*new_width/w_row[j]));
					resized = true;
				}

				if (resized) {
					// Set style
					var old_style = elem.attr('style');
					var new_style = old_style + "; " +
						"background-image: url('" + new_1ximg_url + "'), url('/ApacheGallery/modern/squares.gif'); " +
						"background-image: image-set(url(" + new_1ximg_url + ") 1x, url(" + new_2ximg_url + ") 2x, url(" + new_3ximg_url + ") 3x), url('/ApacheGallery/modern/squares.gif');" +
						"background-image: -webkit-image-set(url(" + new_1ximg_url + ") 1x, url(" + new_2ximg_url + ") 2x, url(" + new_3ximg_url + ") 3x), url('/ApacheGallery/modern/squares.gif');" +
						"background-image: -moz-image-set(url(" + new_1ximg_url + ") 1x, url(" + new_2ximg_url + ") 2x, url(" + new_3ximg_url + ") 3x), url('/ApacheGallery/modern/squares.gif');" +
						"background-image: -ms-image-set(url(" + new_1ximg_url + ") 1x, url(" + new_2ximg_url + ") 2x, url(" + new_3ximg_url + ") 3x), url('/ApacheGallery/modern/squares.gif');";
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

	infoHidden = !infoHidden;
	if (!infoHidden) {
		$('body').addClass(infoClass);
		smallmap(llat, llong, status);
	}
	else {
		$('body').removeClass(infoClass);
	}

	infoInitialised = true;
	put('infoShown', !infoHidden);
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
	if (!mapHidden) {
		$('#map').css("width",$('#mapcontainer').innerWidth());
		map.updateSize();
	}
});

$(document).ready(function() {
	adjustPhotoWidths();
	tileNicely();

	if (get('infoShown') == 'true') {
		toggleInfo();
	}

	if (get('mapShown') == 'true') {
		toggleInfo();
	}
});
