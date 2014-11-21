var debugOn = false;

var map, template, photos, select;

var storedSliderPos = -1;
var mapHidden = false;

OpenLayers.ImgPath = "/ApacheGallery/";

// Called from the HTML to produce a map for an index page
// Initialise index page map (though does not show it).
function bigMap() {
	map = new OpenLayers.Map();
	map.addControl(new OpenLayers.Control.LayerSwitcher());

	// Load base maps
	var base;
	if (debugOn) {
		// Local copy of OSM (useful when testing)
		base = new OpenLayers.Layer.OSM("OSM on IG", "http://ig/ig/map/tiles/${z}/${x}/${y}.png");
	}
	else {
		base = new OpenLayers.Layer.OSM();
	}
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

	// Add layers to map
	map.addLayers([base, photos, ghyb, gsat]);

	// Define select (hover) on markers behaviour
	select = new OpenLayers.Control.SelectFeature(
		photos, {hover: true}
	);
	map.addControl(select);
	select.activate();
	photos.events.on({"featureselected": highlight});
}

// Resize index map
function moveSlider(x) {
	if (!mapHidden) storedSliderPos = x;

	$('#slider').css("left",x+3);
	$('#files').css("width",x-6);
	$('#map').css("width",$('body').innerWidth()-x-12);

	map.updateSize();
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
		debug("At least "+photos.features.length+" photos");
		initMapElements();

		// No idea why it's necessary to call this twice.  Calling once centres on the first cluster,
		// called a second time all the other clusters are shown too.
		map.zoomToExtent(event.object.getDataExtent());
		map.zoomToExtent(event.object.getDataExtent());
	}
	else {
		debug("No photos");
	}
}

// Called by the map if there are geotagged photos
function initMapElements() {
	$('#mapcontainer').css("display","block");
	$('#mapcontainer').css("visibility","hidden");

	// Put the slider 2/3 of the way across
	x = $('body').innerWidth() * 0.66;
	moveSlider(x);
	$('#mapcontainer').css("visibility","visible");

	// Put the map in its div
	map.render("map");

	// Set up slider events (to resize map)
	$('#slider').bind('mousedown', function(event) {
		$(document).bind('mouseup', function(event) {
			$(document).unbind('mousemove');
		});
		$(document).bind('mousemove', function(event) {
			var x = event.pageX;
			if (x > $('body').innerWidth() - 10) {
				x = $('body').innerWidth() - 10;
			}
			moveSlider(x);
		});
		return false;
	});

	// Add the 'hide map' button, set up events
	var hide = $('#mapcontainer').after('<div id="hidemap">Hide map</div>');
	$('#hidemap').bind('click', function() {
		mapHidden = !mapHidden;
		if (!mapHidden) {
			moveSlider(storedSliderPos);
			$('#mapcontainer').css("display","block");
		}
		else {
			moveSlider($('body').innerWidth());
			$('#mapcontainer').css("display","none");
		}
		$('#hidemap').toggleClass('showmap');
		undimAll();
	});

	// Set up events to highlight cluster contaning photos
	$('#files a').bind('mouseover', function() {
		var find = $(this).attr("id");
		//debug("finding "+find);

		// Select the cluster containing the photograph
		for (i = 0; i < photos.features.length; i++) {
			var feature = photos.features[i];
			select.unselect(feature);
			for (j = 0; j < feature.cluster.length; j++) {
				var cluster = feature.cluster[j];
				//debug("fid: "+cluster.fid);
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
			scrollTop: $(jq(idstring)).offset().top
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

// Called from the HTML to produce a map for a photo page.
// Initialise map, and display it.
function smallmap(llat, llong, status) {
	map = new OpenLayers.Map('map', { controls: [] });
	map.addControl(new OpenLayers.Control.MouseToolbar());

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

// Debug thing.
function debug(string) {
	if (debugOn) {
		$('#debug').css("display", "block");
		$('#debug').append(string+"\n");
	}
}

// Dump object (not written by me, found on the web)
var MAX_DUMP_DEPTH = 10;

function dumpObj(obj, name, indent, depth) {
    if (depth > MAX_DUMP_DEPTH) {
	return indent + name + ": <Maximum Depth Reached>\n";
    }
    if (typeof obj == "object") {
	var child = null;
	var output = indent + name + "\n";
	indent += "\t";
	for (var item in obj)
	{
	    try {
		child = obj[item];
	    } catch (e) {
		child = "<Unable to Evaluate>";
	    }
	    if (typeof child == "object") {
		output += dumpObj(child, item, indent, depth + 1);
	    } else {
		output += indent + item + ": " + child + "\n";
	    }
	}
	return output;
    } else {
	return obj;
    }
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
}

$(window).resize(adjustPhotoWidths);

$(document).ready(function() {
	adjustPhotoWidths();
});
