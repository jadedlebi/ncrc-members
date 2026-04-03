(function () {
    'use strict';

        const MAPBOX_PUBLIC_ACCESS_TOKEN = window.MAPBOX_PUBLIC_ACCESS_TOKEN || '';
        if (!MAPBOX_PUBLIC_ACCESS_TOKEN) {
            console.error('Missing Mapbox public token: set MAPBOX_PUBLIC_ACCESS_TOKEN for Cloud Run or js/config.js locally (see .env.example).');
        }
        mapboxgl.accessToken = MAPBOX_PUBLIC_ACCESS_TOKEN;

        if (
            MAPBOX_PUBLIC_ACCESS_TOKEN === 'PLACEHOLDER_UPDATE_ME' ||
            (MAPBOX_PUBLIC_ACCESS_TOKEN && String(MAPBOX_PUBLIC_ACCESS_TOKEN).indexOf('PLACEHOLDER') === 0)
        ) {
            console.error(
                'Mapbox public token is still the Secret Manager placeholder. Replace mapbox-members-public-token with your real pk. token, then redeploy the web service (see README).'
            );
            return;
        }

        // Vector tilesets + source-layers from env (see .env.example): state choropleth + member circles.
        const MAPBOX_STYLE_URL = window.MAPBOX_STYLE_URL || '';
        const MAPBOX_TILESET_URL = window.MAPBOX_TILESET_URL || '';
        const STATE_BOUNDARIES_TILESET_URL = window.STATE_BOUNDARIES_TILESET_URL || '';
        const MEMBERS_SOURCE_LAYER = window.MEMBERS_SOURCE_LAYER || 'ncrc-members-weekly';
        const STATE_BOUNDARIES_SOURCE_LAYER = window.STATE_BOUNDARIES_SOURCE_LAYER || 'State_Shoreline-al2frv';
        const MEMBERS_STATE_COUNTS_REFRESH_SEC = Number(window.MEMBERS_STATE_COUNTS_REFRESH_SEC || 0);
        /** When set, choropleth uses these counts (same source as the export job). Tile query alone is incomplete at low zoom. */
        let serverStateCounts = null;
        let isStateSelected = false;

        if (!MAPBOX_STYLE_URL) {
            console.error('Missing MAPBOX_STYLE_URL: set in private .env and deploy, or js/config.js for local dev (see .env.example).');
            return;
        }

        const map = new mapboxgl.Map({
            container: 'map', // Container ID
            style: MAPBOX_STYLE_URL,
            projection: {
                name: 'mercator'
            },
            center: [-96, 37.8],
            zoom: 3
        });

        // Add geolocate control to the map to find user location
        map.addControl(new mapboxgl.GeolocateControl({
            positionOptions: { enableHighAccuracy: true },
            trackUserLocation: true,
            showUserHeading: true
        }));

        // Add search bar (Geocoder control)
        const geocoder = new MapboxGeocoder({
            accessToken: mapboxgl.accessToken,
            mapboxgl: mapboxgl
        });
        
        // First add the geocoder
        document.getElementById('search-bar').appendChild(geocoder.onAdd(map));
        
        // Then add the reset button
        const resetButton = document.createElement('div');
        resetButton.id = 'reset-button';
        resetButton.innerHTML = `
            <button type="button">
                <img src="assets/us-outline2.png" alt="Show all states">
                <span class="reset-hover-text">Show all states</span>
            </button>
        `;
        document.getElementById('search-bar').appendChild(resetButton);
        resetButton.querySelector('button').addEventListener('click', resetMap);

        /**
         * Choropleth: min → max on a sqrt scale so a few high-count states don’t flatten everyone else.
         * (Linear interpolation on √count spreads mid-range differences more fairly for skewed totals.)
         */
        function buildStateFillColorExpression(minCount, maxCount) {
            const nullGray = '#d3d3d3';
            const lightAtMin = '#e8f0ff';
            const midRamp = '#4a90e2';
            const darkAtMax = '#052142';
            let lo = minCount;
            let hi = maxCount;
            if (hi < lo) {
                const t = lo;
                lo = hi;
                hi = t;
            }
            if (hi === lo && hi === 0) {
                return ['case', ['==', ['feature-state', 'member_count'], null], nullGray, nullGray];
            }
            if (hi === lo) {
                return ['case', ['==', ['feature-state', 'member_count'], null], nullGray, midRamp];
            }
            const count = ['coalesce', ['feature-state', 'member_count'], 0];
            const sqrtCount = ['^', count, 0.5];
            const sqrtLo = Math.sqrt(lo);
            const sqrtHi = Math.sqrt(hi);
            const sqrtMid = Math.sqrt((lo + hi) / 2);
            return [
                'case',
                ['==', ['feature-state', 'member_count'], null],
                nullGray,
                ['interpolate', ['linear'], sqrtCount, sqrtLo, lightAtMin, sqrtMid, midRamp, sqrtHi, darkAtMax]
            ];
        }

        /** Stable key so each company point is counted once (querySourceFeatures can return duplicates across tiles). */
        function memberFeatureDedupeKey(f) {
            if (f.id !== undefined && f.id !== null) {
                return 'id:' + String(f.id);
            }
            const p = f.properties || {};
            const g = f.geometry;
            if (g && g.type === 'Point' && Array.isArray(g.coordinates) && g.coordinates.length >= 2) {
                return 'pt:' + String(g.coordinates[0]) + ',' + String(g.coordinates[1]) + '|' + String(p.state || '') + '|' + String(p.company_na || '');
            }
            return 'fb:' + String(p.state || '') + '|' + String(p.company_na || '');
        }

        /** Resolve counts URL. HTTPS APIs use a stable URL so browser + server Cache-Control can cache; local JSON uses no-store. */
        function buildCountsFetchUrl(base) {
            if (!base || typeof base !== 'string') {
                return base;
            }
            const t = base.trim();
            if (t === '') {
                return t;
            }
            if (/^https?:\/\//i.test(t)) {
                return t;
            }
            return new URL(t, window.location.href).href;
        }

        // forceNetwork: skip browser HTTP cache (use for interval refresh so each tick can see updated Cache-Control / server data).
        async function loadServerStateCounts(forceNetwork) {
            const explicit = typeof window.MEMBERS_STATE_COUNTS_URL === 'string' ? window.MEMBERS_STATE_COUNTS_URL.trim() : '';
            const urls = explicit ? [buildCountsFetchUrl(explicit)] : [buildCountsFetchUrl('/data/state_counts.json')];
            const fetchCacheMode = explicit ? (forceNetwork ? 'no-store' : 'default') : 'no-store';
            for (let i = 0; i < urls.length; i += 1) {
                try {
                    const r = await fetch(urls[i], { cache: fetchCacheMode });
                    if (r.ok) {
                        const j = await r.json();
                        if (j && typeof j === 'object' && !Array.isArray(j)) {
                            serverStateCounts = j;
                            return;
                        }
                    }
                } catch (e) {
                    /* ignore */
                }
            }
            serverStateCounts = null;
            if (!explicit) {
                console.warn(
                    'No data/state_counts.json — state totals from the map may be low at default zoom (vector tiles omit points until zoomed in). Run: SKIP_MAPBOX_UPLOAD=1 python3 job/main.py (writes data/state_counts.json), or set MEMBERS_STATE_COUNTS_URL.'
                );
            }
        }

        // Load the map layers and sources
        map.on('load', async () => {
            if (!STATE_BOUNDARIES_TILESET_URL || !MAPBOX_TILESET_URL) {
                console.error('Set STATE_BOUNDARIES_TILESET_URL and MAPBOX_TILESET_URL (see .env.example / docker-entrypoint).');
                return;
            }
            await loadServerStateCounts();
            map.addSource('state-boundaries', {
                type: 'vector',
                url: STATE_BOUNDARIES_TILESET_URL
            });

            map.addLayer({
                id: 'state-fill',
                type: 'fill',
                source: 'state-boundaries',
                'source-layer': STATE_BOUNDARIES_SOURCE_LAYER,
                paint: {
                    // Replaced on each calculateAndApplyMemberCounts() from actual min/max totals
                    'fill-color': buildStateFillColorExpression(0, 0),
                    'fill-opacity': 0.6
                }
            }); 

            map.addLayer({
                id: 'state-outline',
                type: 'line',
                source: 'state-boundaries',
                'source-layer': STATE_BOUNDARIES_SOURCE_LAYER,
                paint: {
                    'line-color': '#000000',
                    'line-width': 1.5
                }
            });

            map.addSource('members', {
                type: 'vector',
                url: MAPBOX_TILESET_URL
            });

            map.addLayer({
                id: 'members-layer',
                type: 'circle',
                source: 'members',
                'source-layer': MEMBERS_SOURCE_LAYER,
                paint: {
                    'circle-radius': 8,
                    'circle-color': '#173B4A',
                    'circle-opacity': 0.6, 
                    'circle-stroke-width': 2
                },
                layout: {
                    visibility: 'visible'
                }
            });

            map.addLayer({
                id: 'members-layer-hover',
                type: 'circle',
                source: 'members',
                'source-layer': MEMBERS_SOURCE_LAYER,
                paint: {
                    'circle-radius': [
                        'case',
                        ['boolean', ['feature-state', 'hover'], false],
                        8, // Larger radius on hover
                        0   // Hide when not hovered
                    ],
                    'circle-color': [
                        'case',
                        ['boolean', ['feature-state', 'hover'], false],
                        '#173B4A', // Highlight color on hover
                        'rgba(0,0,0,0)' // Transparent when not hovered
                    ],
                    'circle-stroke-width': [
                        'case',
                        ['boolean', ['feature-state', 'hover'], false],
                        4, // Thicker stroke on hover
                        0 // No stroke when not hovered
                    ],
                    'circle-stroke-color': 'black'
                }
            });

            map.addLayer({
                id: 'members-highlight',
                type: 'circle',
                source: 'members',
                'source-layer': MEMBERS_SOURCE_LAYER,
                paint: {
                    'circle-radius': 15,
                    'circle-color': '#FFC23A',
                    'circle-opacity': 1,
                    'circle-stroke-width': 3,
                    'circle-stroke-color': '#FFFFFF'
                },
                layout: {
                    'visibility': 'none'
                }
            });

            waitForSources();

            // Track the currently hovered feature
            let hoveredFeatureId = null;

            // Hover effect for state-fill
            map.on('mouseenter', 'state-fill', (e) => {
                // Change the cursor to pointer
                map.getCanvas().style.cursor = 'pointer';
                // Highlight the hovered state with darker opacity
                map.setPaintProperty('state-fill', 'fill-opacity', [
                    'case',
                    ['boolean', ['feature-state', 'hover'], false], 0.8, // Darker opacity on hover
                    0.6 // Default opacity
                ]);
            });

            let hoveredStateId = null;
            map.on('mousemove', 'state-fill', (e) => {
                let memberPopup;
                if (hoveredStateId !== null) {
                    map.setFeatureState(
                        { source: 'state-boundaries', sourceLayer: STATE_BOUNDARIES_SOURCE_LAYER, id: hoveredStateId },
                        { hover: false }
                    );
                }
                hoveredStateId = e.features[0].id;
                map.setFeatureState(
                    { source: 'state-boundaries', sourceLayer: STATE_BOUNDARIES_SOURCE_LAYER, id: hoveredStateId },
                    { hover: true }
                );
                // Get the state name and member count from the feature state
                const stateName = e.features[0].properties.NAME10; // Replace 'NAME' with the property for the state name
                const memberCount = e.features[0].state.member_count || 0; // Default to 0 if no count is set
                if (memberCount === 1) {
                    memberPopup = ' member'
                } else {
                    memberPopup = ' members'
                }
                // Set popup content
                popupState
                    .setLngLat(e.lngLat)
                    .setHTML(`
                        <strong style='font-size:20px;'>${stateName}<br>
                        ${memberCount}</strong>${memberPopup}<br>
                        <p style='font-style:italic;line-height:0.1;'>Click to view members.</body>
                        `)
                    .addTo(map);
            });
            map.on('mouseleave', 'state-fill', () => {
                // Reset the cursor to default
                map.getCanvas().style.cursor = '';
                // Remove the hover effect
                map.setPaintProperty('state-fill', 'fill-opacity', 0.6);
                popupState.remove();
                if (hoveredStateId !== null) {
                    map.setFeatureState(
                        { source: 'state-boundaries', sourceLayer: STATE_BOUNDARIES_SOURCE_LAYER, id: hoveredStateId },
                        { hover: false }
                    );
                }
                hoveredStateId = null;
            });

            // Initialize a popup instance outside of event listeners
            const popup = new mapboxgl.Popup({
                closeButton: false,
                closeOnClick: false,
                offset: 15
            });

            // Initialize a popup instance outside of event listeners
            const popupState = new mapboxgl.Popup({
                closeButton: false,
                closeOnClick: false,
                offset: 15
            });

            // Show popup on hover
            map.on('mouseenter', 'members-layer', (e) => {
                // Change cursor to pointer
                map.getCanvas().style.cursor = 'pointer';
                // Set the hover layer's visibility to visible
                if (e.features.length > 0) {
                    if (hoveredFeatureId) {
                        map.setFeatureState(
                            { source: 'members', sourceLayer: MEMBERS_SOURCE_LAYER, id: hoveredFeatureId },
                            { hover: false }
                        );
                    }
                    hoveredFeatureId = e.features[0].id;
                    map.setFeatureState(
                        { source: 'members', sourceLayer: MEMBERS_SOURCE_LAYER, id: hoveredFeatureId },
                        { hover: true }
                    );
                    // Show the hover layer
                    map.setLayoutProperty('members-layer-hover', 'visibility', 'visible');
                }

                // Set popup content based on properties of the hovered feature
                const coordinates = e.features[0].geometry.coordinates.slice();
                const member = '<strong>' + e.features[0].properties.company_na + '</strong>'
                const address1 = e.features[0].properties.address;
                const address2 = e.features[0].properties.city + ', ' + e.features[0].properties.state + ' ' + e.features[0].properties.zip1
                const url = e.features[0].properties.url; // Ensure 'url' exists in the feature properties
                const urlVisible = url ? 'Click to view website.' : 'No website available for this member.';
                // Set popup content and location
                popup
                    .setLngLat(coordinates)
                    .setHTML(`
                        <strong style='font-size:20px;'>${member}</strong>
                        <p style='font-size:15px;line-height:1;'>${address1}<br>
                        ${address2}</p>
                         <p style='font-style:italic;line-height:1;'>${urlVisible}</p>
                        `)
                    .addTo(map);
            });

            // Update popup position on mousemove (optional for smoother interaction)
            map.on('mousemove', 'members-layer', (e) => {
                popup.setLngLat(e.lngLat);
                map.getCanvas().style.cursor = 'pointer';
                // Reset the previous feature's hover state
                if (hoveredFeatureId && hoveredFeatureId !== e.features[0].id) {
                    map.setFeatureState(
                        { source: 'members', sourceLayer: MEMBERS_SOURCE_LAYER, id: hoveredFeatureId },
                        { hover: false }
                    );
                }
                // Set the hover state for the new feature
                hoveredFeatureId = e.features[0].id;
                map.setFeatureState(
                    { source: 'members', sourceLayer: MEMBERS_SOURCE_LAYER, id: hoveredFeatureId },
                    { hover: true }
                );
            });

            // Remove popup and reset cursor on mouse leave
            map.on('mouseleave', 'members-layer', () => {
                map.getCanvas().style.cursor = ''; // Reset cursor
                popup.remove(); // Remove popup
                // Hide the hover layer and reset the feature state
                if (hoveredFeatureId) {
                    map.setFeatureState(
                        { source: 'members', sourceLayer: MEMBERS_SOURCE_LAYER, id: hoveredFeatureId },
                        { hover: false }
                    );
                }
                hoveredFeatureId = null;
                map.setLayoutProperty('members-layer-hover', 'visibility', 'none');
            });

            // Hide all member dots until a state is selected. (Do not use ['==', ['get', 'state'], ''] — that
            // SHOWS only features with empty state; one orphan coordinate can appear as a random dot.)
            const hideAllMemberPointsFilter = ['==', ['geometry-type'], 'Polygon'];
            if (map.getLayer('members-layer')) {
                map.setFilter('members-layer', hideAllMemberPointsFilter);
                map.setFilter('members-layer-hover', hideAllMemberPointsFilter);
            } else {
                console.error("Layer 'members-layer' not found on load.");
            }

            map.on('click', 'state-fill', (e) => {
                const stateName = e.features[0].properties.STUSPS10;
                const stateFullName = e.features[0].properties.NAME10;
                isStateSelected = true;
                
                // Set fill to transparent for selected state
                map.setPaintProperty('state-fill', 'fill-opacity', 0);
                map.setPaintProperty('state-outline', 'line-width', 3);
                map.setFilter('state-outline', ['==', ['get', 'STUSPS10'], stateName]);
                map.setFilter('state-fill', ['!=', ['get', 'STUSPS10'], stateName]);
                
                // Show member locations for the selected state
                if (map.getLayer('members-layer')) {
                    map.setFilter('members-layer', ['==', ['get', 'state'], stateName]);
                    map.setFilter('members-layer-hover', ['==', ['get', 'state'], stateName]);
                    map.setLayoutProperty('members-layer', 'visibility', 'visible');
                }

                const coordinates = e.features[0].geometry.coordinates;
                function extractCoordinates(coord) {
                    const result = [];
                    coord.forEach(item => {
                        if (Array.isArray(item[0])) {
                            result.push(...extractCoordinates(item));
                        } else if (item.length === 2 && !isNaN(item[0]) && !isNaN(item[1])) {
                            result.push([item[0], item[1]]);
                        }
                    });
                    return result;
                }
                const validCoordinates = extractCoordinates(coordinates);
                if (validCoordinates.length === 0) {
                    console.error('No valid coordinates found for bounds calculation');
                    return;
                }
                const bounds = validCoordinates.reduce((bounds, coord) => {
                    return bounds.extend(coord);
                }, new mapboxgl.LngLatBounds(validCoordinates[0], validCoordinates[0]));
                map.fitBounds(bounds, { 
                    padding: {
                        top: 20,
                        bottom: 20,
                        left: 20,
                        right: 220  // Increased right padding to account for the 200px wide member list + some margin
                    },
                    duration: 500
                });
                map.once('idle', () => {
                    if (map.getLayer('members-layer')) {
                        console.log(`Filtering 'members-layer' for state: ${stateName}`);
                        map.setFilter('members-layer', ['==', ['get', 'state'], stateName]);
                        map.setLayoutProperty('members-layer', 'visibility', 'visible'); // Ensure visibility is set to 'visible'
                    } else {
                        console.error("'members-layer' is not loaded or accessible.");
                    }
                });
                popupState.remove();

                // Ensure the member list is displayed by waiting for the map to finish loading
                map.once('idle', () => {
                    // Query and display members for the clicked state
                    const members = map.querySourceFeatures('members', {
                        sourceLayer: MEMBERS_SOURCE_LAYER,
                        filter: ['==', ['get', 'state'], stateName]
                    });
                    
                    // Remove duplicate entries based on company_na
                    const uniqueMembers = Array.from(new Set(members.map(m => m.properties.company_na)))
                        .map(name => members.find(m => m.properties.company_na === name));
                    
                    const listContainer = document.getElementById('member-list-container');
                    const memberList = document.getElementById('member-list');
                    const header = listContainer.querySelector('.member-list-header');
                    
                    // Clear existing list
                    memberList.innerHTML = '';
                    
                    // Update header with state name and member count
                    header.textContent = `${stateFullName} Members`;
                    
                    // Sort members alphabetically by company name
                    uniqueMembers.sort((a, b) => 
                        a.properties.company_na.localeCompare(b.properties.company_na)
                    );
                    
                    // Add members to list
                    uniqueMembers.forEach(member => {
                        const item = document.createElement('div');
                        item.className = 'member-list-item';
                        item.textContent = member.properties.company_na;
                        
                        // Add hover and click handlers
                        item.addEventListener('mouseenter', () => {
                            map.setFilter('members-highlight', [
                                'all',
                                ['==', ['get', 'state'], stateName],
                                ['==', ['get', 'company_na'], member.properties.company_na]
                            ]);
                            map.setLayoutProperty('members-highlight', 'visibility', 'visible');
                        });
                        
                        item.addEventListener('mouseleave', () => {
                            map.setLayoutProperty('members-highlight', 'visibility', 'none');
                        });
                        
                        item.addEventListener('click', () => {
                            const url = member.properties.url;
                            if (url) {
                                const fullUrl = url.startsWith('http') ? url : `https://${url}`;
                                window.open(fullUrl, '_blank');
                            }
                        });
                        
                        memberList.appendChild(item);
                    });
                    
                    // Show the list container
                    listContainer.style.display = 'block';
                });
            });

            // Add popups for member locations
            map.on('click', 'members-layer', (e) => {
                console.log("Member location properties:", e.features[0].properties);
                const coordinates = e.features[0].geometry.coordinates.slice();
                const url = e.features[0].properties.url;
                if (url) {
                    const fullUrl = url.startsWith('http') ? url : `https://${url}`;
                    window.open(fullUrl, '_blank');
                } else {
                    console.error('No URL found for this member location');
                }
            });

            map.on('sourcedata', onSourceDataLoaded);

            // Add this function after map.on('load', ...)
            function logMemberCounts() {
                let sortedCounts;
                if (serverStateCounts) {
                    sortedCounts = Object.fromEntries(
                        Object.entries(serverStateCounts).sort(([a], [b]) => a.localeCompare(b))
                    );
                    console.log('Member counts by state (from state_counts.json — same as choropleth):', sortedCounts);
                    return;
                }
                const memberCounts = {};
                const seen = new Set();
                const features = map.querySourceFeatures('members', { sourceLayer: MEMBERS_SOURCE_LAYER });

                features.forEach(function (feature) {
                    const dk = memberFeatureDedupeKey(feature);
                    if (seen.has(dk)) return;
                    seen.add(dk);
                    const state = feature.properties.state;
                    if (state) {
                        memberCounts[state] = (memberCounts[state] || 0) + 1;
                    }
                });

                sortedCounts = Object.fromEntries(
                    Object.entries(memberCounts).sort(([a], [b]) => a.localeCompare(b))
                );

                console.log('Member counts by state (from vector tiles — incomplete at low zoom; add data/state_counts.json for full totals):', sortedCounts);
            }

            // Add this line inside map.on('load', ...) after all layers are added
            map.once('idle', logMemberCounts);

            if (MEMBERS_STATE_COUNTS_REFRESH_SEC > 0) {
                setInterval(function () {
                    loadServerStateCounts(true).then(function () {
                        if (map.isSourceLoaded('state-boundaries') && map.isSourceLoaded('members')) {
                            calculateAndApplyMemberCounts();
                        }
                    });
                }, MEMBERS_STATE_COUNTS_REFRESH_SEC * 1000);
            }
        });

        // Listen for map events where we only reset `state-fill` if `isStateSelected` is false
        map.on('mouseenter', () => {
            if (!isStateSelected) {
                map.setPaintProperty('state-fill', 'fill-opacity', 0.4);
            }
        });
        map.on('mouseleave', () => {
            if (!isStateSelected) {
                map.setPaintProperty('state-fill', 'fill-opacity', 0.4);
            }
        });

        // Geocoder result event to zoom and show details for a state
        geocoder.on('result', (e) => {
            const result = e.result;
            const placeType = result.place_type[0]; // Get the type of place (e.g., 'region' for state)

            if (placeType === 'region') {
                // Handle state zoom and filter member locations based on the selected state
                map.fitBounds(result.bbox, { padding: 20 });
                map.setFilter('members-layer', ['==', ['get', 'state'], result.text]);
            }
        });

        // Add this function to check if sources are loaded
        function waitForSources() {
            if (!map.isSourceLoaded('state-boundaries') || !map.isSourceLoaded('members')) {
                setTimeout(waitForSources, 100); // Retry after 100 ms
            } else {
                onSourceDataLoaded(); // Call once when sources are fully loaded
            }
        }

        // Function to handle source data loading
        function onSourceDataLoaded() {
            if (map.isSourceLoaded('state-boundaries') && map.isSourceLoaded('members')) {
                // Apply default member counts to avoid null warnings
                applyDefaultMemberCounts();
                // Calculate and apply actual member counts
                calculateAndApplyMemberCounts();
            }
        }

        function calculateAndApplyMemberCounts() {
            const stateFeatures = map.querySourceFeatures('state-boundaries', { sourceLayer: STATE_BOUNDARIES_SOURCE_LAYER });
            
            if (stateFeatures.length === 0) {
                console.warn("No state features found in 'state-boundaries'. Check source layer name.");
                return;
            }

            const memberCounts = {};
            const seenMemberDedupe = new Set();
            if (serverStateCounts) {
                Object.keys(serverStateCounts).forEach(function (k) {
                    const n = Number(serverStateCounts[k]);
                    if (!isNaN(n)) {
                        memberCounts[k] = n;
                    }
                });
            } else {
                map.querySourceFeatures('members', { sourceLayer: MEMBERS_SOURCE_LAYER }).forEach((f) => {
                    const dk = memberFeatureDedupeKey(f);
                    if (seenMemberDedupe.has(dk)) {
                        return;
                    }
                    seenMemberDedupe.add(dk);
                    const s = f.properties.state;
                    if (s) memberCounts[s] = (memberCounts[s] || 0) + 1;
                });
            }

            const perStateTotals = [];
            stateFeatures.forEach((stateFeature) => {
                const stateCode = stateFeature.properties.STUSPS10;
                if (stateCode) {
                    perStateTotals.push(memberCounts[stateCode] || 0);
                }
            });
            const minTotal = perStateTotals.length ? Math.min(...perStateTotals) : 0;
            const maxTotal = perStateTotals.length ? Math.max(...perStateTotals) : 0;

            stateFeatures.forEach((stateFeature) => {
                const stateId = stateFeature.id;
                const stateCode = stateFeature.properties.STUSPS10;
                if (stateCode) {
                    const count = memberCounts[stateCode] || 0;
                    map.setFeatureState(
                        { source: 'state-boundaries', sourceLayer: STATE_BOUNDARIES_SOURCE_LAYER, id: stateId },
                        { member_count: count }
                    );
                }
            });

            if (map.getLayer('state-fill')) {
                map.setPaintProperty('state-fill', 'fill-color', buildStateFillColorExpression(minTotal, maxTotal));
            }

            map.triggerRepaint();
        }

        function applyDefaultMemberCounts() {
            const stateFeatures = map.querySourceFeatures('state-boundaries', { sourceLayer: STATE_BOUNDARIES_SOURCE_LAYER });
            if (stateFeatures.length === 0) {
                console.warn("No state features found in 'state-boundaries'. Check source layer name.");
                return;
            }
            // Set default member count of 0 for each state to prevent null warnings
            stateFeatures.forEach((stateFeature) => {
                const stateId = stateFeature.id;
                map.setFeatureState(
                    { source: 'state-boundaries', sourceLayer: STATE_BOUNDARIES_SOURCE_LAYER, id: stateId },
                    { member_count: 0 } // Default to 0 to avoid nulls
                );
            });
        }

        // Update the resetMap function
        function resetMap() {
            console.log("Reset map function started");
            
            // Hide member layer dots immediately
            if (map.getLayer('members-layer')) {
                map.setLayoutProperty('members-layer', 'visibility', 'none');
                map.setFilter('members-layer', null);
                map.setFilter('members-layer-hover', null);
            }
            
            // Hide member list container
            const listContainer = document.getElementById('member-list-container');
            listContainer.style.display = 'none';
            
            map.flyTo({
                center: [-96, 37.8],
                zoom: 3,
                duration: 1000
            });
            
            // Wait for the animation to complete before resetting other properties
            map.once('moveend', () => {
                // Reset map filters and properties
                map.setFilter('state-fill', null);
                map.setPaintProperty('state-fill', 'fill-opacity', 0.6);
                map.setFilter('state-outline', null);
                map.setPaintProperty('state-outline', 'line-width', 1.5);
                
                // Reset state selection flag
                isStateSelected = false;
                
                // Clear member list
                const memberList = document.getElementById('member-list');
                if (memberList) {
                    memberList.innerHTML = '';
                }

                // Wait for sources to be loaded before calculating counts
                waitForSources();
            });

            // Reset the highlight layer
            map.setLayoutProperty('members-highlight', 'visibility', 'none');
            map.setFilter('members-highlight', null);
        }
})();
